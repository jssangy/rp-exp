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

class S5bSubscriber : public rclcpp::Node
{
public:
  S5bSubscriber()
  : Node("s5b_subscriber"), running_(true),
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

    RCLCPP_INFO(get_logger(),
      "S5-b subscriber started (로보택시): "
      "/cmd_vel /imu /points /camera/front /camera/side /depth/image_raw");
  }

  ~S5bSubscriber()
  {
    running_ = false;
    cv_.notify_all();
    if (proc_thread_.joinable()) { proc_thread_.join(); }
    std::printf("[S5-b] FINAL received: cmd %lu | imu %lu | pts %lu | front %lu | side %lu | depth %lu msgs\n",
      total_cmd_.load(), total_imu_.load(), total_pts_.load(),
      total_front_.load(), total_side_.load(), total_depth_.load());
  }

private:
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

        double latency_ms = (recv_time - stamp_of(msg)).nanoseconds() / 1e6;

        ++window_count;
        latency_sum += latency_ms;
        if (latency_ms > latency_max) latency_max = latency_ms;

        auto now_steady = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now_steady - window_start).count();
        if (elapsed >= 5.0) {
          RCLCPP_INFO(get_logger(),
            "recv 5s | cmd %.1f | imu %.1f | pts %.1f | front %.1f | side %.1f | depth %.1f Hz"
            " | latency avg %.2f ms max %.2f ms",
            recv_cmd_.load()   / elapsed,
            recv_imu_.load()   / elapsed,
            recv_pts_.load()   / elapsed,
            recv_front_.load() / elapsed,
            recv_side_.load()  / elapsed,
            recv_depth_.load() / elapsed,
            latency_sum / window_count, latency_max);
          window_start = now_steady;
          recv_cmd_ = recv_imu_ = recv_pts_ = recv_front_ = recv_side_ = recv_depth_ = 0;
          window_count = 0;
          latency_sum  = 0.0;
          latency_max  = 0.0;
        }

        lk.lock();
      }
    }
  }

  void count(const CmdMsg::SharedPtr &) { ++recv_cmd_;   ++total_cmd_; }
  void count(const ImuMsg::SharedPtr &) { ++recv_imu_;   ++total_imu_; }
  void count(const PtsMsg::SharedPtr &) { ++recv_pts_;   ++total_pts_; }
  void count(const Front &)             { ++recv_front_; ++total_front_; }
  void count(const Side &)              { ++recv_side_;  ++total_side_; }
  void count(const ImgMsg::SharedPtr &) { ++recv_depth_; ++total_depth_; }

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

  std::atomic<uint64_t> recv_cmd_, recv_imu_, recv_pts_;
  std::atomic<uint64_t> recv_front_, recv_side_, recv_depth_;
  std::atomic<uint64_t> total_cmd_{0}, total_imu_{0}, total_pts_{0};
  std::atomic<uint64_t> total_front_{0}, total_side_{0}, total_depth_{0};
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
