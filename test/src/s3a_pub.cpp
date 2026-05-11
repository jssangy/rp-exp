#include <chrono>
#include <cmath>
#include <memory>

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/laser_scan.hpp>

static constexpr double HZ         = 40.0;
static constexpr int    NUM_BEAMS  = 1080;   // Hokuyo UST-10LX 기준, ~4.3 KB
static constexpr float  RANGE_VAL  = 5.0f;   // 고정 거리값 (m)

class S3aPublisher : public rclcpp::Node
{
public:
  explicit S3aPublisher(uint64_t max_count)
  : Node("s3a_publisher"), pub_count_(0), max_count_(max_count)
  {
    rclcpp::QoS qos(1);
    qos.best_effort();
    pub_ = create_publisher<sensor_msgs::msg::LaserScan>("/scan", qos);

    // 메시지 초기화 시 한 번만 할당
    msg_ = std::make_shared<sensor_msgs::msg::LaserScan>();
    msg_->header.frame_id = "laser";
    msg_->angle_min       = -M_PI;
    msg_->angle_max       =  M_PI;
    msg_->angle_increment = 2.0 * M_PI / NUM_BEAMS;
    msg_->scan_time       = 1.0 / HZ;
    msg_->time_increment  = msg_->scan_time / NUM_BEAMS;
    msg_->range_min       = 0.1f;
    msg_->range_max       = 30.0f;

    // ranges 배열 초기화 후 재사용 (resize는 여기서만)
    msg_->ranges.resize(NUM_BEAMS, RANGE_VAL);

    auto period = std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::duration<double>(1.0 / HZ));
    timer_ = create_wall_timer(period, [this]() { timer_cb(); });

    RCLCPP_INFO(get_logger(),
      "S3-a publisher started: %.1f Hz, %d beams, max %lu msgs, BEST_EFFORT",
      HZ, NUM_BEAMS, max_count_);
  }

private:
  void timer_cb()
  {
    msg_->header.stamp = now();
    pub_->publish(*msg_);
    ++pub_count_;

    if (max_count_ > 0 && pub_count_ >= max_count_) {
      RCLCPP_INFO(get_logger(), "DONE: published %lu msgs", pub_count_);
      timer_->cancel();
      rclcpp::shutdown();
      return;
    }
    if (pub_count_ % 200 == 0) {
      RCLCPP_INFO(get_logger(), "published %lu msgs", pub_count_);
    }
  }

  rclcpp::Publisher<sensor_msgs::msg::LaserScan>::SharedPtr pub_;
  rclcpp::TimerBase::SharedPtr timer_;
  sensor_msgs::msg::LaserScan::SharedPtr msg_;
  uint64_t pub_count_;
  uint64_t max_count_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);

  uint64_t max_count = static_cast<uint64_t>(HZ * 60.0);
  if (args.size() > 1) {
    max_count = std::stoull(args[1]);
  }

  auto node = std::make_shared<S3aPublisher>(max_count);

  rclcpp::executors::MultiThreadedExecutor exec;
  exec.add_node(node);
  exec.spin();

  rclcpp::shutdown();
  return 0;
}
