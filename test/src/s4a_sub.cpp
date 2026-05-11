#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>

static constexpr uint64_t EXPECTED = 30 * 60;  // 30 Hz × 60 s

class S4aSubscriber : public rclcpp::Node
{
public:
  S4aSubscriber()
  : Node("s4a_subscriber"), running_(true), measuring_(false), recv_count_(0)
  {
    rclcpp::QoS qos(1);
    qos.best_effort();
    sub_ = create_subscription<sensor_msgs::msg::CompressedImage>(
      "/image_raw/compressed", qos,
      [this](sensor_msgs::msg::CompressedImage::SharedPtr msg) { enqueue(std::move(msg)); });

    proc_thread_ = std::thread(&S4aSubscriber::process_loop, this);

    using namespace std::chrono_literals;
    timer_warmup_ = create_wall_timer(10s, [this]() {
      measuring_ = true;
      timer_warmup_->cancel();
      timer_measure_ = create_wall_timer(60s, [this]() {
        uint64_t recv = recv_count_.load();
        RCLCPP_INFO(get_logger(),
          "FINAL [60s]: recv %lu / expected %lu → drop %.1f%%",
          recv, EXPECTED,
          100.0 * (EXPECTED - std::min(recv, EXPECTED)) / EXPECTED);
        rclcpp::shutdown();
      });
    });

    RCLCPP_INFO(get_logger(), "S4-a subscriber started: BEST_EFFORT (10s warmup + 60s measure)");
  }

  ~S4aSubscriber()
  {
    running_ = false;
    cv_.notify_all();
    if (proc_thread_.joinable()) { proc_thread_.join(); }
  }

private:
  void enqueue(sensor_msgs::msg::CompressedImage::SharedPtr msg)
  {
    { std::lock_guard<std::mutex> lk(mtx_); queue_.push(std::move(msg)); }
    cv_.notify_one();
  }

  void process_loop()
  {
    std::chrono::steady_clock::time_point window_start;
    bool window_started = false;
    uint64_t window_count = 0;
    double latency_sum = 0.0, latency_max = 0.0;
    size_t last_payload_kb = 0;

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
          last_payload_kb = msg->data.size() / 1024;
          auto recv_time = now();
          double latency_ms = (recv_time - msg->header.stamp).nanoseconds() / 1e6;
          ++recv_count_;
          ++window_count;
          latency_sum += latency_ms;
          if (latency_ms > latency_max) latency_max = latency_ms;

          auto now_steady = std::chrono::steady_clock::now();
          double elapsed = std::chrono::duration<double>(now_steady - window_start).count();
          if (elapsed >= 5.0) {
            RCLCPP_INFO(get_logger(),
              "recv %lu msgs | rate %.1f Hz | payload %zu KB | latency avg %.2f ms max %.2f ms",
              recv_count_.load(), window_count / elapsed, last_payload_kb,
              latency_sum / window_count, latency_max);
            window_start = now_steady;
            window_count = 0;
            latency_sum  = 0.0;
            latency_max  = 0.0;
          }
        }

        lk.lock();
      }
    }
  }

  rclcpp::Subscription<sensor_msgs::msg::CompressedImage>::SharedPtr sub_;
  std::queue<sensor_msgs::msg::CompressedImage::SharedPtr> queue_;
  std::mutex mtx_;
  std::condition_variable cv_;
  std::thread proc_thread_;
  std::atomic<bool> running_;
  std::atomic<bool> measuring_;
  std::atomic<uint64_t> recv_count_;
  rclcpp::TimerBase::SharedPtr timer_warmup_, timer_measure_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  auto node = std::make_shared<S4aSubscriber>();
  rclcpp::executors::MultiThreadedExecutor exec;
  exec.add_node(node);
  exec.spin();
  rclcpp::shutdown();
  return 0;
}
