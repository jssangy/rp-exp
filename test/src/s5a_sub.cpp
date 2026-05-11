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

class S5aSubscriber : public rclcpp::Node
{
public:
  S5aSubscriber()
  : Node("s5a_subscriber"), running_(true),
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

    RCLCPP_INFO(get_logger(),
      "S5-a subscriber started (실내 AMR): /cmd_vel /imu /scan /image_raw/compressed");
  }

  ~S5aSubscriber()
  {
    running_ = false;
    cv_.notify_all();
    if (proc_thread_.joinable()) { proc_thread_.join(); }
  }

private:
  template<typename T>
  void enqueue(T msg)
  {
    { std::lock_guard<std::mutex> lk(mtx_); queue_.push(AnyMsg{std::move(msg)}); }
    cv_.notify_one();
  }

  void process_loop()
  {
    auto window_start = std::chrono::steady_clock::now();
    double latency_sum = 0.0;
    double latency_max = 0.0;
    uint64_t window_count = 0;

    while (running_) {
      std::unique_lock<std::mutex> lk(mtx_);
      cv_.wait(lk, [this]() { return !queue_.empty() || !running_; });

      while (!queue_.empty()) {
        auto msg = std::move(queue_.front());
        queue_.pop();
        lk.unlock();

        auto recv_time = now();
        std::visit([this](auto && m) { count(m); }, msg);

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
            recv_cmd_.load()  / elapsed,
            recv_imu_.load()  / elapsed,
            recv_scan_.load() / elapsed,
            recv_cam_.load()  / elapsed,
            latency_sum / window_count, latency_max);
          window_start = now_steady;
          recv_cmd_ = recv_imu_ = recv_scan_ = recv_cam_ = 0;
          window_count = 0;
          latency_sum  = 0.0;
          latency_max  = 0.0;
        }

        lk.lock();
      }
    }
  }

  void count(const CmdMsg::SharedPtr &)  { ++recv_cmd_; }
  void count(const ImuMsg::SharedPtr &)  { ++recv_imu_; }
  void count(const ScanMsg::SharedPtr &) { ++recv_scan_; }
  void count(const CamMsg::SharedPtr &)  { ++recv_cam_; }

  rclcpp::Subscription<CmdMsg>::SharedPtr  sub_cmd_;
  rclcpp::Subscription<ImuMsg>::SharedPtr  sub_imu_;
  rclcpp::Subscription<ScanMsg>::SharedPtr sub_scan_;
  rclcpp::Subscription<CamMsg>::SharedPtr  sub_cam_;

  std::queue<AnyMsg> queue_;
  std::mutex mtx_;
  std::condition_variable cv_;
  std::thread proc_thread_;
  std::atomic<bool> running_;

  std::atomic<uint64_t> recv_cmd_, recv_imu_, recv_scan_, recv_cam_;
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
