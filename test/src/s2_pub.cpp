#include <chrono>
#include <memory>

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/imu.hpp>

class S2Publisher : public rclcpp::Node
{
public:
  explicit S2Publisher(double hz)
  : Node("s2_publisher"), pub_count_(0)
  {
    rclcpp::QoS qos(1);
    qos.best_effort();
    pub_ = create_publisher<sensor_msgs::msg::Imu>("/imu", qos);

    // 메시지 초기화 시 한 번만 할당, 이후 재사용
    // CDR 페이로드: orientation(32B) + 공분산 3개(216B) + angular_velocity(24B)
    //              + linear_acceleration(24B) ≈ 320B
    msg_ = std::make_shared<sensor_msgs::msg::Imu>();
    msg_->header.frame_id = "imu_link";

    msg_->orientation.w = 1.0;
    msg_->orientation.x = 0.0;
    msg_->orientation.y = 0.0;
    msg_->orientation.z = 0.0;

    msg_->angular_velocity.x = 0.01;
    msg_->angular_velocity.y = 0.00;
    msg_->angular_velocity.z = 0.00;

    msg_->linear_acceleration.x = 0.0;
    msg_->linear_acceleration.y = 0.0;
    msg_->linear_acceleration.z = 9.81;

    // 대각 공분산 행렬 (9 × float64 = 72B 각각)
    msg_->orientation_covariance[0] = 1e-6;
    msg_->orientation_covariance[4] = 1e-6;
    msg_->orientation_covariance[8] = 1e-6;

    msg_->angular_velocity_covariance[0] = 1e-6;
    msg_->angular_velocity_covariance[4] = 1e-6;
    msg_->angular_velocity_covariance[8] = 1e-6;

    msg_->linear_acceleration_covariance[0] = 1e-4;
    msg_->linear_acceleration_covariance[4] = 1e-4;
    msg_->linear_acceleration_covariance[8] = 1e-4;

    auto period = std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::duration<double>(1.0 / hz));
    timer_ = create_wall_timer(period, [this]() { timer_cb(); });

    RCLCPP_INFO(get_logger(), "S2 publisher started: %.1f Hz, BEST_EFFORT", hz);
  }

private:
  void timer_cb()
  {
    // header stamp은 매 콜백마다 갱신 (시퀀스 추적용)
    msg_->header.stamp = now();
    pub_->publish(*msg_);

    if (++pub_count_ % 1000 == 0) {
      RCLCPP_INFO(get_logger(), "published %lu msgs", pub_count_);
    }
  }

  rclcpp::Publisher<sensor_msgs::msg::Imu>::SharedPtr pub_;
  rclcpp::TimerBase::SharedPtr timer_;
  sensor_msgs::msg::Imu::SharedPtr msg_;
  uint64_t pub_count_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);

  double hz = 200.0;
  if (argc > 1) {
    hz = std::stod(argv[1]);
  }

  auto node = std::make_shared<S2Publisher>(hz);

  rclcpp::executors::MultiThreadedExecutor exec;
  exec.add_node(node);
  exec.spin();

  rclcpp::shutdown();
  return 0;
}
