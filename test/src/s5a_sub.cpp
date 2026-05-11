#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>
#include <variant>

#include <rclcpp/rclcpp.hpp>
#include <geometry_msgs/msg/twist_stamped.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>
#include <sensor_msgs/msg/imu.hpp>
#include <sensor_msgs/msg/laser_scan.hpp>

using CmdMsg  = geometry_msgs::msg::TwistStamped;
using ImuMsg  = sensor_msgs::msg::Imu;
using ScanMsg = sensor_msgs::msg::LaserScan;
using CamMsg  = sensor_msgs::msg::CompressedImage;
using AnyMsg  = std::variant<
  CmdMsg::SharedPtr,
  ImuMsg::SharedPtr,
  ScanMsg::SharedPtr,
  CamMsg::SharedPtr>;

// expected per topic: Hz × 60 s
static constexpr uint64_t EXP_CMD  = 20  * 60;
static constexpr uint64_t EXP_IMU  = 200 * 60;
static constexpr uint64_t EXP_SCAN = 40  * 60;
static constexpr uint64_t EXP_CAM  = 30  * 60;

class S5aSubscriber : public rclcpp::Node
{
public:
  S5aSubscriber()
  : Node("s5a_subscriber"), running_(true), measuring_(false),
    recv_cmd_(0), recv_imu_(0), recv_scan_(0), recv_cam_(0)
  {
    rclcpp::QoS qos(1);
    qos.best_effort();

    sub_cmd_  = create_subscription<CmdMsg>("/cmd_vel", qos,
      [this](CmdMsg::SharedPtr m)  { enqueue(std::move(m)); });
    sub_imu_  = create_subscription<ImuMsg>("/imu", qos,
      [this](ImuMsg::SharedPtr m)  { enqueue(std::move(m)); });
    sub_scan_ = create_subscription<ScanMsg>("/scan", qos,
      [this](ScanMsg::SharedPtr m) { enqueue(std::move(m)); });
    sub_cam_  = create_subscription<CamMsg>("/image_raw/compressed", qos,
      [this](CamMsg::SharedPtr m)  { enqueue(std::move(m)); });

    proc_thread_ = std::thread(&S5aSubscriber::process_loop, this);

    using namespace std::chrono_literals;
    timer_warmup_ = create_wall_timer(10s, [this]() {
      measuring_ = true;
      timer_warmup_->cancel();
      timer_measure_ = create_wall_timer(60s, [this]() {
        RCLCPP_INFO(get_logger(),
          "FINAL [60s]:"
          " cmd %lu/%lu(%.1f%%)"
          " imu %lu/%lu(%.1f%%)"
          " scan %lu/%lu(%.1f%%)"
          " cam %lu/%lu(%.1f%%)",
          recv_cmd_.load(),  EXP_CMD,  drop_pct(recv_cmd_.load(),  EXP_CMD),
          recv_imu_.load(),  EXP_IMU,  drop_pct(recv_imu_.load(),  EXP_IMU),
          recv_scan_.load(), EXP_SCAN, drop_pct(recv_scan_.load(), EXP_SCAN),
          recv_cam_.load(),  EXP_CAM,  drop_pct(recv_cam_.load(),  EXP_CAM));
        rclcpp::shutdown();
      });
    });

    RCLCPP_INFO(get_logger(),
      "S5-a subscriber started (실내 AMR): /cmd_vel /imu /scan /image_raw/compressed"
      " (10s warmup + 60s measure)");
  }

  ~S5aSubscriber()
  {
    running_ = false;
    cv_.notify_all();
    if (proc_thread_.joinable()) { proc_thread_.join(); }
  }

private:
  static double drop_pct(uint64_t recv, uint64_t expected)
  {
    return 100.0 * (expected - std::min(recv, expected)) / expected;
  }

  template<typename T>
  void enqueue(T msg)
  {
    { std::lock_guard<std::mutex> lk(mtx_); queue_.push(AnyMsg{std::move(msg)}); }
    cv_.notify_one();
  }

  void process_loop()
  {
    std::chrono::steady_clock::time_point window_start;
    bool window_started = false;
    double latency_sum = 0.0, latency_max = 0.0;
    uint64_t window_count = 0;
    // window-local per-topic counters (reset every 5s)
    uint64_t w_cmd = 0, w_imu = 0, w_scan = 0, w_cam = 0;

    while (running_) {
      std::unique_lock<std::mutex> lk(mtx_);
      cv_.wait(lk, [this]() { return !queue_.empty() || !running_; });

      while (!queue_.empty()) {
        auto msg = std::move(queue_.front());
        queue_.pop();
        lk.unlock();

        if (measuring_) {
          if (!window_started) {
            window_start = std::chrono::steady_clock::now();
            window_started = true;
          }
          count(msg, w_cmd, w_imu, w_scan, w_cam);

          auto recv_time = now();
          double latency_ms = std::visit([&](auto && m) {
            return (recv_time - m->header.stamp).nanoseconds() / 1e6;
          }, msg);

          ++window_count;
          latency_sum += latency_ms;
          if (latency_ms > latency_max) latency_max = latency_ms;

          auto now_steady = std::chrono::steady_clock::now();
          double elapsed = std::chrono::duration<double>(now_steady - window_start).count();
          if (elapsed >= 5.0) {
            RCLCPP_INFO(get_logger(),
              "recv 5s | /cmd_vel %.1fHz | /imu %.1fHz | /scan %.1fHz | /compressed %.1fHz"
              " | latency avg %.2f ms max %.2f ms",
              w_cmd / elapsed, w_imu / elapsed, w_scan / elapsed, w_cam / elapsed,
              latency_sum / window_count, latency_max);
            window_start = now_steady;
            w_cmd = w_imu = w_scan = w_cam = window_count = 0;
            latency_sum = 0.0;
            latency_max = 0.0;
          }
        }

        lk.lock();
      }
    }
  }

  void count(const AnyMsg & msg, uint64_t & wc, uint64_t & wi, uint64_t & ws, uint64_t & wm)
  {
    std::visit([&](auto && m) {
      using T = std::decay_t<decltype(m)>;
      if constexpr (std::is_same_v<T, CmdMsg::SharedPtr>)  { ++recv_cmd_;  ++wc; }
      else if constexpr (std::is_same_v<T, ImuMsg::SharedPtr>)  { ++recv_imu_;  ++wi; }
      else if constexpr (std::is_same_v<T, ScanMsg::SharedPtr>) { ++recv_scan_; ++ws; }
      else if constexpr (std::is_same_v<T, CamMsg::SharedPtr>)  { ++recv_cam_;  ++wm; }
    }, msg);
  }

  rclcpp::Subscription<CmdMsg>::SharedPtr  sub_cmd_;
  rclcpp::Subscription<ImuMsg>::SharedPtr  sub_imu_;
  rclcpp::Subscription<ScanMsg>::SharedPtr sub_scan_;
  rclcpp::Subscription<CamMsg>::SharedPtr  sub_cam_;

  std::queue<AnyMsg> queue_;
  std::mutex mtx_;
  std::condition_variable cv_;
  std::thread proc_thread_;
  std::atomic<bool> running_;
  std::atomic<bool> measuring_;

  // measurement-window totals
  std::atomic<uint64_t> recv_cmd_, recv_imu_, recv_scan_, recv_cam_;

  rclcpp::TimerBase::SharedPtr timer_warmup_, timer_measure_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  auto node = std::make_shared<S5aSubscriber>();
  rclcpp::executors::MultiThreadedExecutor exec;
  exec.add_node(node);
  exec.spin();
  rclcpp::shutdown();
  return 0;
}
