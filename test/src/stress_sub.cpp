#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/image.hpp>

class StressSubscriber : public rclcpp::Node
{
public:
  StressSubscriber(double expected_hz, int warmup_sec, int measure_sec, const std::string & topic)
  : Node("stress_subscriber"),
    expected_hz_(expected_hz),
    warmup_sec_(warmup_sec),
    measure_sec_(measure_sec),
    running_(true),
    measuring_(false),
    recv_count_(0),
    window_count_(0)
  {
    rclcpp::QoS qos(1);
    qos.best_effort();
    sub_ = create_subscription<sensor_msgs::msg::Image>(
      topic, qos,
      [this](sensor_msgs::msg::Image::ConstSharedPtr msg) {
        (void)msg;
        if (measuring_.load(std::memory_order_relaxed)) {
          recv_count_.fetch_add(1, std::memory_order_relaxed);
          window_count_.fetch_add(1, std::memory_order_relaxed);
        }
      });

    control_thread_ = std::thread(&StressSubscriber::measurement_loop, this);

    RCLCPP_INFO(
      get_logger(),
      "Stress subscriber started: topic=%s, expected=%.1f Hz, BEST_EFFORT (%ds warmup + %ds measure)",
      topic.c_str(), expected_hz_, warmup_sec_, measure_sec_);
  }

  ~StressSubscriber() override
  {
    running_ = false;
    if (control_thread_.joinable()) {
      control_thread_.join();
    }
  }

private:
  void measurement_loop()
  {
    using namespace std::chrono_literals;
    std::this_thread::sleep_for(std::chrono::seconds(warmup_sec_));

    recv_count_ = 0;
    window_count_ = 0;
    measuring_ = true;

    auto window_start = std::chrono::steady_clock::now();
    const auto measure_start = window_start;
    while (running_ && rclcpp::ok()) {
      std::this_thread::sleep_for(100ms);
      const auto now = std::chrono::steady_clock::now();
      const double total_elapsed = std::chrono::duration<double>(now - measure_start).count();
      const double window_elapsed = std::chrono::duration<double>(now - window_start).count();

      if (window_elapsed >= 5.0) {
        const uint64_t window = window_count_.exchange(0);
        RCLCPP_INFO(
          get_logger(), "recv %lu msgs | rate %.1f Hz",
          recv_count_.load(std::memory_order_relaxed), window / window_elapsed);
        window_start = now;
      }

      if (total_elapsed >= static_cast<double>(measure_sec_)) {
        measuring_ = false;
        const uint64_t recv = recv_count_.load(std::memory_order_relaxed);
        const uint64_t expected = static_cast<uint64_t>(expected_hz_ * measure_sec_ + 0.5);
        const uint64_t capped = std::min(recv, expected);
        const double drop = expected == 0 ? 0.0 :
          100.0 * static_cast<double>(expected - capped) / static_cast<double>(expected);
        std::printf("FINAL [%ds]: recv %lu / expected %lu -> drop %.1f%%\n",
          measure_sec_, recv, expected, drop);
        std::fflush(stdout);
        rclcpp::shutdown();
        break;
      }
    }
  }

  rclcpp::Subscription<sensor_msgs::msg::Image>::SharedPtr sub_;
  double expected_hz_;
  int warmup_sec_;
  int measure_sec_;
  std::atomic<bool> running_;
  std::atomic<bool> measuring_;
  std::atomic<uint64_t> recv_count_;
  std::atomic<uint64_t> window_count_;
  std::thread control_thread_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  auto args = rclcpp::remove_ros_arguments(argc, argv);

  double expected_hz = 1000.0;
  if (args.size() > 1) {
    expected_hz = std::stod(args[1]);
  }
  int warmup_sec = 10;
  if (args.size() > 2) {
    warmup_sec = std::stoi(args[2]);
  }
  int measure_sec = 60;
  if (args.size() > 3) {
    measure_sec = std::stoi(args[3]);
  }
  std::string topic = "/stress";
  if (args.size() > 4) {
    topic = args[4];
  }

  if (expected_hz <= 0.0) {
    throw std::invalid_argument("expected_hz must be positive");
  }
  if (warmup_sec < 0 || measure_sec <= 0) {
    throw std::invalid_argument("warmup_sec must be >= 0 and measure_sec must be positive");
  }

  auto node = std::make_shared<StressSubscriber>(expected_hz, warmup_sec, measure_sec, topic);
  rclcpp::executors::MultiThreadedExecutor exec;
  exec.add_node(node);
  exec.spin();

  rclcpp::shutdown();
  return 0;
}
