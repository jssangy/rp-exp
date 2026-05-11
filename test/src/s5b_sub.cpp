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
#include <sensor_msgs/msg/image.hpp>
#include <sensor_msgs/msg/point_cloud2.hpp>

using CmdMsg   = geometry_msgs::msg::TwistStamped;
using ImuMsg   = sensor_msgs::msg::Imu;
using PtsMsg   = sensor_msgs::msg::PointCloud2;
using CamMsg   = sensor_msgs::msg::CompressedImage;
using ImgMsg   = sensor_msgs::msg::Image;

// 토픽별 태그로 variant 구분
struct Front { CamMsg::SharedPtr msg; };
struct Side  { CamMsg::SharedPtr msg; };

using AnyMsg = std::variant<
  CmdMsg::SharedPtr,
  ImuMsg::SharedPtr,
  PtsMsg::SharedPtr,
  Front,
  Side,
  ImgMsg::SharedPtr>;

// expected per topic: Hz × 60 s
static constexpr uint64_t EXP_CMD   = 20  * 60;
static constexpr uint64_t EXP_IMU   = 200 * 60;
static constexpr uint64_t EXP_PTS   = 10  * 60;
static constexpr uint64_t EXP_FRONT = 30  * 60;
static constexpr uint64_t EXP_SIDE  = 30  * 60;
static constexpr uint64_t EXP_DEPTH = 30  * 60;

class S5bSubscriber : public rclcpp::Node
{
public:
  S5bSubscriber()
  : Node("s5b_subscriber"), running_(true), measuring_(false),
    recv_cmd_(0), recv_imu_(0), recv_pts_(0),
    recv_front_(0), recv_side_(0), recv_depth_(0)
  {
    rclcpp::QoS qos(1);
    qos.best_effort();

    sub_cmd_   = create_subscription<CmdMsg>("/cmd_vel", qos,
      [this](CmdMsg::SharedPtr m)  { enqueue(std::move(m)); });
    sub_imu_   = create_subscription<ImuMsg>("/imu", qos,
      [this](ImuMsg::SharedPtr m)  { enqueue(std::move(m)); });
    sub_pts_   = create_subscription<PtsMsg>("/points", qos,
      [this](PtsMsg::SharedPtr m)  { enqueue(std::move(m)); });
    sub_front_ = create_subscription<CamMsg>("/camera/front/compressed", qos,
      [this](CamMsg::SharedPtr m)  { enqueue(Front{std::move(m)}); });
    sub_side_  = create_subscription<CamMsg>("/camera/side/compressed", qos,
      [this](CamMsg::SharedPtr m)  { enqueue(Side{std::move(m)}); });
    sub_depth_ = create_subscription<ImgMsg>("/depth/image_raw", qos,
      [this](ImgMsg::SharedPtr m)  { enqueue(std::move(m)); });

    proc_thread_ = std::thread(&S5bSubscriber::process_loop, this);

    using namespace std::chrono_literals;
    timer_warmup_ = create_wall_timer(10s, [this]() {
      measuring_ = true;
      timer_warmup_->cancel();
      timer_measure_ = create_wall_timer(60s, [this]() {
        RCLCPP_INFO(get_logger(),
          "FINAL [60s]:"
          " cmd %lu/%lu(%.1f%%)"
          " imu %lu/%lu(%.1f%%)"
          " pts %lu/%lu(%.1f%%)"
          " front %lu/%lu(%.1f%%)"
          " side %lu/%lu(%.1f%%)"
          " depth %lu/%lu(%.1f%%)",
          recv_cmd_.load(),   EXP_CMD,   drop_pct(recv_cmd_.load(),   EXP_CMD),
          recv_imu_.load(),   EXP_IMU,   drop_pct(recv_imu_.load(),   EXP_IMU),
          recv_pts_.load(),   EXP_PTS,   drop_pct(recv_pts_.load(),   EXP_PTS),
          recv_front_.load(), EXP_FRONT, drop_pct(recv_front_.load(), EXP_FRONT),
          recv_side_.load(),  EXP_SIDE,  drop_pct(recv_side_.load(),  EXP_SIDE),
          recv_depth_.load(), EXP_DEPTH, drop_pct(recv_depth_.load(), EXP_DEPTH));
        rclcpp::shutdown();
      });
    });

    RCLCPP_INFO(get_logger(),
      "S5-b subscriber started (로보택시): "
      "/cmd_vel /imu /points /camera/front /camera/side /depth/image_raw"
      " (10s warmup + 60s measure)");
  }

  ~S5bSubscriber()
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

  static rclcpp::Time stamp_of(const AnyMsg & m)
  {
    return std::visit([](auto && v) -> rclcpp::Time {
      using T = std::decay_t<decltype(v)>;
      if constexpr (std::is_same_v<T, Front> || std::is_same_v<T, Side>) {
        return v.msg->header.stamp;
      } else {
        return v->header.stamp;
      }
    }, m);
  }

  void process_loop()
  {
    std::chrono::steady_clock::time_point window_start;
    bool window_started = false;
    double latency_sum = 0.0, latency_max = 0.0;
    uint64_t window_count = 0;
    // window-local per-topic counters (reset every 5s)
    uint64_t w_cmd = 0, w_imu = 0, w_pts = 0, w_front = 0, w_side = 0, w_depth = 0;

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
          count(msg, w_cmd, w_imu, w_pts, w_front, w_side, w_depth);

          double latency_ms = (now() - stamp_of(msg)).nanoseconds() / 1e6;
          std::visit([&](auto && m) {
            using T = std::decay_t<decltype(m)>;
            if constexpr (std::is_same_v<T, CmdMsg::SharedPtr>)  std::printf("LAT cmd   %.3f\n", latency_ms);
            else if constexpr (std::is_same_v<T, ImuMsg::SharedPtr>)  std::printf("LAT imu   %.3f\n", latency_ms);
            else if constexpr (std::is_same_v<T, PtsMsg::SharedPtr>)  std::printf("LAT pts   %.3f\n", latency_ms);
            else if constexpr (std::is_same_v<T, Front>)              std::printf("LAT front %.3f\n", latency_ms);
            else if constexpr (std::is_same_v<T, Side>)               std::printf("LAT side  %.3f\n", latency_ms);
            else if constexpr (std::is_same_v<T, ImgMsg::SharedPtr>)  std::printf("LAT depth %.3f\n", latency_ms);
          }, msg);

          ++window_count;
          latency_sum += latency_ms;
          if (latency_ms > latency_max) latency_max = latency_ms;

          auto now_steady = std::chrono::steady_clock::now();
          double elapsed = std::chrono::duration<double>(now_steady - window_start).count();
          if (elapsed >= 5.0) {
            RCLCPP_INFO(get_logger(),
              "recv 5s | cmd %.1f | imu %.1f | pts %.1f | front %.1f | side %.1f | depth %.1f Hz"
              " | latency avg %.2f ms max %.2f ms",
              w_cmd / elapsed, w_imu / elapsed, w_pts / elapsed,
              w_front / elapsed, w_side / elapsed, w_depth / elapsed,
              latency_sum / window_count, latency_max);
            window_start = now_steady;
            w_cmd = w_imu = w_pts = w_front = w_side = w_depth = window_count = 0;
            latency_sum = 0.0;
            latency_max = 0.0;
          }
        }

        lk.lock();
      }
    }
  }

  void count(const AnyMsg & msg,
             uint64_t & wc, uint64_t & wi, uint64_t & wp,
             uint64_t & wf, uint64_t & ws, uint64_t & wd)
  {
    std::visit([&](auto && m) {
      using T = std::decay_t<decltype(m)>;
      if constexpr (std::is_same_v<T, CmdMsg::SharedPtr>)  { ++recv_cmd_;   ++wc; }
      else if constexpr (std::is_same_v<T, ImuMsg::SharedPtr>)  { ++recv_imu_;   ++wi; }
      else if constexpr (std::is_same_v<T, PtsMsg::SharedPtr>)  { ++recv_pts_;   ++wp; }
      else if constexpr (std::is_same_v<T, Front>)              { ++recv_front_; ++wf; }
      else if constexpr (std::is_same_v<T, Side>)               { ++recv_side_;  ++ws; }
      else if constexpr (std::is_same_v<T, ImgMsg::SharedPtr>)  { ++recv_depth_; ++wd; }
    }, msg);
  }

  rclcpp::Subscription<CmdMsg>::SharedPtr  sub_cmd_;
  rclcpp::Subscription<ImuMsg>::SharedPtr  sub_imu_;
  rclcpp::Subscription<PtsMsg>::SharedPtr  sub_pts_;
  rclcpp::Subscription<CamMsg>::SharedPtr  sub_front_;
  rclcpp::Subscription<CamMsg>::SharedPtr  sub_side_;
  rclcpp::Subscription<ImgMsg>::SharedPtr  sub_depth_;

  std::queue<AnyMsg> queue_;
  std::mutex mtx_;
  std::condition_variable cv_;
  std::thread proc_thread_;
  std::atomic<bool> running_;
  std::atomic<bool> measuring_;

  // measurement-window totals
  std::atomic<uint64_t> recv_cmd_, recv_imu_, recv_pts_;
  std::atomic<uint64_t> recv_front_, recv_side_, recv_depth_;

  rclcpp::TimerBase::SharedPtr timer_warmup_, timer_measure_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  auto node = std::make_shared<S5bSubscriber>();
  rclcpp::executors::MultiThreadedExecutor exec;
  exec.add_node(node);
  exec.spin();
  rclcpp::shutdown();
  return 0;
}
