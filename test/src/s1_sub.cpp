#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>

#include <rclcpp/rclcpp.hpp>
#include <geometry_msgs/msg/twist_stamped.hpp>

static constexpr uint64_t EXPECTED = 20 * 60;  // 20 Hz × 60 s

class S1Subscriber : public rclcpp::Node
{
public:
  S1Subscriber()
  : Node("s1_subscriber"), running_(true), measuring_(false), recv_count_(0)
  {
    rclcpp::QoS qos(1);
    qos.best_effort();
    sub_ = create_subscription<geometry_msgs::msg::TwistStamped>(
      "/cmd_vel", qos,
      [this](geometry_msgs::msg::TwistStamped::SharedPtr msg) { enqueue(std::move(msg)); });

    proc_thread_ = std::thread(&S1Subscriber::process_loop, this);

    using namespace std::chrono_literals;
    timer_warmup_ = create_wall_timer(10s, [this]() {
      measuring_ = true;
      timer_warmup_->cancel();
      timer_measure_ = create_wall_timer(60s, [this]() {
        uint64_t recv = recv_count_.load();
        std::printf("FINAL [60s]: recv %lu / expected %lu -> drop %.1f%%\n",
          recv, EXPECTED,
          100.0 * (EXPECTED - std::min(recv, EXPECTED)) / EXPECTED);
        std::fflush(stdout);
        rclcpp::shutdown();
      });
    });

    RCLCPP_INFO(get_logger(), "S1 subscriber started: BEST_EFFORT (10s warmup + 60s measure)");
  }

  ~S1Subscriber()
  {
    running_ = false;
    cv_.notify_all();
    if (proc_thread_.joinable()) { proc_thread_.join(); }
  }

private:
  void enqueue(geometry_msgs::msg::TwistStamped::SharedPtr msg)
  {
    { std::lock_guard<std::mutex> lk(mtx_); queue_.push(std::move(msg)); }
    cv_.notify_one();
  }

  void process_loop()
  {
    std::chrono::steady_clock::time_point window_start;
    bool window_started = false;
    uint64_t window_count = 0;

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
          ++recv_count_;
          ++window_count;

          auto now_steady = std::chrono::steady_clock::now();
          double elapsed = std::chrono::duration<double>(now_steady - window_start).count();
          if (elapsed >= 5.0) {
            RCLCPP_INFO(get_logger(),
              "recv %lu msgs | rate %.1f Hz",
              recv_count_.load(), window_count / elapsed);
            window_start = now_steady;
            window_count = 0;
          }
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
  std::atomic<bool> measuring_;
  std::atomic<uint64_t> recv_count_;
  rclcpp::TimerBase::SharedPtr timer_warmup_, timer_measure_;
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
