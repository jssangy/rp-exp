#include <chrono>
#include <memory>
#include <stdexcept>

#include <rclcpp/rclcpp.hpp>
#include <geometry_msgs/msg/twist.hpp>

class S1Publisher : public rclcpp::Node
{
public:
  explicit S1Publisher(double hz)
  : Node("s1_publisher"), pub_count_(0)
  {
    // BEST_EFFORT + KEEP_LAST(1)
    rclcpp::QoS qos(1);
    qos.best_effort();
    pub_ = create_publisher<geometry_msgs::msg::Twist>("/cmd_vel", qos);

    // 메시지 초기화 시 한 번만 할당, 이후 재사용
    msg_ = std::make_shared<geometry_msgs::msg::Twist>();
    msg_->linear.x  = 0.5;
    msg_->linear.y  = 0.0;
    msg_->linear.z  = 0.0;
    msg_->angular.x = 0.0;
    msg_->angular.y = 0.0;
    msg_->angular.z = 0.3;

    auto period = std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::duration<double>(1.0 / hz));
    timer_ = create_wall_timer(period, [this]() { timer_cb(); });

    RCLCPP_INFO(get_logger(), "S1 publisher started: %.1f Hz, BEST_EFFORT", hz);
  }

private:
  void timer_cb()
  {
    pub_->publish(*msg_);

    if (++pub_count_ % 200 == 0) {
      RCLCPP_INFO(get_logger(), "published %lu msgs", pub_count_);
    }
  }

  rclcpp::Publisher<geometry_msgs::msg::Twist>::SharedPtr pub_;
  rclcpp::TimerBase::SharedPtr timer_;
  geometry_msgs::msg::Twist::SharedPtr msg_;
  uint64_t pub_count_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  auto args = rclcpp::remove_ros_arguments(argc, argv);

  double hz = 20.0;
  if (args.size() > 1) {
    hz = std::stod(args[1]);
  }
  if (hz > 50.0) {
    RCLCPP_WARN(rclcpp::get_logger("s1_pub"), "Hz %.1f > 50 (S1 상한), 50으로 제한", hz);
    hz = 50.0;
  }

  auto node = std::make_shared<S1Publisher>(hz);

  rclcpp::executors::MultiThreadedExecutor exec;
  exec.add_node(node);
  exec.spin();

  rclcpp::shutdown();
  return 0;
}
