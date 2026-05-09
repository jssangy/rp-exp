#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>

class S4aSubscriber : public rclcpp::Node
{
public:
  S4aSubscriber()
  : Node("s4a_subscriber"), running_(true), recv_count_(0)
  {
    rclcpp::QoS qos(1);
    qos.best_effort();
    sub_ = create_subscription<sensor_msgs::msg::CompressedImage>(
      "/image_raw/compressed", qos,
      [this](sensor_msgs::msg::CompressedImage::SharedPtr msg) { enqueue(std::move(msg)); });

    proc_thread_ = std::thread(&S4aSubscriber::process_loop, this);

    RCLCPP_INFO(get_logger(), "S4-a subscriber started: BEST_EFFORT");
  }

  ~S4aSubscriber()
  {
    running_ = false;
    cv_.notify_all();
    if (proc_thread_.joinable()) {
      proc_thread_.join();
    }
  }

private:
  void enqueue(sensor_msgs::msg::CompressedImage::SharedPtr msg)
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

    while (running_) {
      std::unique_lock<std::mutex> lk(mtx_);
      cv_.wait(lk, [this]() { return !queue_.empty() || !running_; });

      while (!queue_.empty()) {
        auto msg = std::move(queue_.front());
        queue_.pop();
        lk.unlock();

        ++recv_count_;
        ++window_count;

        auto now = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - window_start).count();
        if (elapsed >= 5.0) {
          RCLCPP_INFO(get_logger(),
            "total %lu msgs | rate %.1f Hz | payload %zu KB",
            recv_count_.load(), window_count / elapsed, msg->data.size() / 1024);
          window_start = now;
          window_count = 0;
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
  std::atomic<uint64_t> recv_count_;
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
