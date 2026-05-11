#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>

#include <rclcpp/rclcpp.hpp>
#include <geometry_msgs/msg/twist_stamped.hpp>

class S1Subscriber : public rclcpp::Node
{
public:
  S1Subscriber()
  : Node("s1_subscriber"), running_(true), recv_count_(0)
  {
    // BEST_EFFORT + KEEP_LAST(1)
    rclcpp::QoS qos(1);
    qos.best_effort();
    sub_ = create_subscription<geometry_msgs::msg::TwistStamped>(
      "/cmd_vel", qos,
      [this](geometry_msgs::msg::TwistStamped::SharedPtr msg) { enqueue(std::move(msg)); });

    proc_thread_ = std::thread(&S1Subscriber::process_loop, this);

    RCLCPP_INFO(get_logger(), "S1 subscriber started: BEST_EFFORT");
  }

  ~S1Subscriber()
  {
    running_ = false;
    cv_.notify_all();
    if (proc_thread_.joinable()) {
      proc_thread_.join();
    }
    std::printf("[S1] FINAL received: %lu msgs\n", recv_count_.load());
  }

private:
  void enqueue(geometry_msgs::msg::TwistStamped::SharedPtr msg)
  {
    {
      std::lock_guard<std::mutex> lk(mtx_);
      queue_.push(std::move(msg));
    }
    cv_.notify_one();
  }

  void process_loop()
  {
    auto window_start = std::chrono::steady_clock::now();
    uint64_t window_count = 0;
    double latency_sum = 0.0;
    double latency_max = 0.0;

    while (running_) {
      std::unique_lock<std::mutex> lk(mtx_);
      cv_.wait(lk, [this]() { return !queue_.empty() || !running_; });

      while (!queue_.empty()) {
        auto msg = std::move(queue_.front());
        queue_.pop();
        lk.unlock();

        auto recv_time = now();
        double latency_ms =
          (recv_time - msg->header.stamp).nanoseconds() / 1e6;

        ++recv_count_;
        ++window_count;
        latency_sum += latency_ms;
        if (latency_ms > latency_max) latency_max = latency_ms;

        auto now_steady = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now_steady - window_start).count();
        if (elapsed >= 5.0) {
          RCLCPP_INFO(get_logger(),
            "total %lu msgs | rate %.1f Hz | latency avg %.2f ms max %.2f ms",
            recv_count_.load(),
            window_count / elapsed,
            latency_sum / window_count,
            latency_max);
          window_start = now_steady;
          window_count = 0;
          latency_sum  = 0.0;
          latency_max  = 0.0;
        }

        lk.lock();
      }
    }
  }

  rclcpp::Subscription<geometry_msgs::msg::TwistStamped>::SharedPtr sub_;
  std::queue<geometry_msgs::msg::TwistStamped::SharedPtr> queue_;
  std::mutex mtx_;
  std::condition_variable cv_;
  std::thread proc_thread_;
  std::atomic<bool> running_;
  std::atomic<uint64_t> recv_count_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);

  auto node = std::make_shared<S1Subscriber>();

  rclcpp::executors::MultiThreadedExecutor exec;
  exec.add_node(node);
  exec.spin();

  rclcpp::shutdown();
  return 0;
}
