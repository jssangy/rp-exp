#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>
#include <variant>

#include <rclcpp/rclcpp.hpp>
#include <geometry_msgs/msg/twist.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>
#include <sensor_msgs/msg/imu.hpp>
#include <sensor_msgs/msg/image.hpp>
#include <sensor_msgs/msg/point_cloud2.hpp>

using CmdMsg   = geometry_msgs::msg::Twist;
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

    while (running_) {
      std::unique_lock<std::mutex> lk(mtx_);
      cv_.wait(lk, [this]() { return !queue_.empty() || !running_; });

      while (!queue_.empty()) {
        auto msg = std::move(queue_.front());
        queue_.pop();
        lk.unlock();

        std::visit([this](auto && m) { count(m); }, msg);

        auto now = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - window_start).count();
        if (elapsed >= 5.0) {
          RCLCPP_INFO(get_logger(),
            "recv 5s | cmd %.1f | imu %.1f | pts %.1f | front %.1f | side %.1f | depth %.1f Hz",
            recv_cmd_.load()   / elapsed,
            recv_imu_.load()   / elapsed,
            recv_pts_.load()   / elapsed,
            recv_front_.load() / elapsed,
            recv_side_.load()  / elapsed,
            recv_depth_.load() / elapsed);
          window_start = now;
          recv_cmd_ = recv_imu_ = recv_pts_ = recv_front_ = recv_side_ = recv_depth_ = 0;
        }

        lk.lock();
      }
    }
  }

  void count(const CmdMsg::SharedPtr &) { ++recv_cmd_; }
  void count(const ImuMsg::SharedPtr &) { ++recv_imu_; }
  void count(const PtsMsg::SharedPtr &) { ++recv_pts_; }
  void count(const Front &)             { ++recv_front_; }
  void count(const Side &)              { ++recv_side_; }
  void count(const ImgMsg::SharedPtr &) { ++recv_depth_; }

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
