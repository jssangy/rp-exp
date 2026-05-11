#include <chrono>
#include <cmath>
#include <memory>

#include <rclcpp/rclcpp.hpp>
#include <geometry_msgs/msg/twist_stamped.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>
#include <sensor_msgs/msg/imu.hpp>
#include <sensor_msgs/msg/laser_scan.hpp>

// S5-a: 실내 AMR — /cmd_vel(20Hz) + /imu(200Hz) + /scan(40Hz) + /image_raw/compressed(30Hz)
static constexpr double   HZ_CMD      = 20.0;
static constexpr double   HZ_IMU      = 200.0;
static constexpr double   HZ_SCAN     = 40.0;
static constexpr double   HZ_CAM      = 30.0;
static constexpr int      NUM_BEAMS   = 1080;
static constexpr float    RANGE_VAL   = 5.0f;
static constexpr uint32_t JPEG_SIZE_B = 150 * 1024;

class S5aPublisher : public rclcpp::Node
{
public:
  explicit S5aPublisher(double duration_s)
  : Node("s5a_publisher"),
    cnt_cmd_(0), cnt_imu_(0), cnt_scan_(0), cnt_cam_(0),
    duration_s_(duration_s)
  {
    rclcpp::QoS qos(1);
    qos.best_effort();

    pub_cmd_  = create_publisher<geometry_msgs::msg::TwistStamped>("/cmd_vel", qos);
    pub_imu_  = create_publisher<sensor_msgs::msg::Imu>("/imu", qos);
    pub_scan_ = create_publisher<sensor_msgs::msg::LaserScan>("/scan", qos);
    pub_cam_  = create_publisher<sensor_msgs::msg::CompressedImage>("/image_raw/compressed", qos);

    init_cmd();
    init_imu();
    init_scan();
    init_cam();

    auto make_timer = [this](double hz, auto cb) {
      auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::duration<double>(1.0 / hz));
      return create_wall_timer(ns, cb);
    };

    timer_cmd_  = make_timer(HZ_CMD,  [this]() { pub_cmd(); });
    timer_imu_  = make_timer(HZ_IMU,  [this]() { pub_imu(); });
    timer_scan_ = make_timer(HZ_SCAN, [this]() { pub_scan(); });
    timer_cam_  = make_timer(HZ_CAM,  [this]() { pub_cam(); });

    auto shutdown_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::duration<double>(duration_s));
    timer_shutdown_ = create_wall_timer(shutdown_ns, [this]() {
      RCLCPP_INFO(get_logger(),
        "DONE (%.0fs): cmd %lu | imu %lu | scan %lu | cam %lu msgs",
        duration_s_, cnt_cmd_, cnt_imu_, cnt_scan_, cnt_cam_);
      rclcpp::shutdown();
    });

    RCLCPP_INFO(get_logger(),
      "S5-a publisher started (실내 AMR): "
      "/cmd_vel %.0fHz | /imu %.0fHz | /scan %.0fHz | /image_raw/compressed %.0fHz | %.0fs",
      HZ_CMD, HZ_IMU, HZ_SCAN, HZ_CAM, duration_s_);
  }

private:
  void init_cmd()
  {
    msg_cmd_ = std::make_shared<geometry_msgs::msg::TwistStamped>();
    msg_cmd_->header.frame_id    = "base_link";
    msg_cmd_->twist.linear.x     = 0.5;
    msg_cmd_->twist.angular.z    = 0.3;
  }

  void init_imu()
  {
    msg_imu_ = std::make_shared<sensor_msgs::msg::Imu>();
    msg_imu_->header.frame_id = "imu_link";
    msg_imu_->orientation.w   = 1.0;
    msg_imu_->linear_acceleration.z = 9.81;
    msg_imu_->orientation_covariance[0]         = 1e-6;
    msg_imu_->orientation_covariance[4]         = 1e-6;
    msg_imu_->orientation_covariance[8]         = 1e-6;
    msg_imu_->angular_velocity_covariance[0]    = 1e-6;
    msg_imu_->angular_velocity_covariance[4]    = 1e-6;
    msg_imu_->angular_velocity_covariance[8]    = 1e-6;
    msg_imu_->linear_acceleration_covariance[0] = 1e-4;
    msg_imu_->linear_acceleration_covariance[4] = 1e-4;
    msg_imu_->linear_acceleration_covariance[8] = 1e-4;
  }

  void init_scan()
  {
    msg_scan_ = std::make_shared<sensor_msgs::msg::LaserScan>();
    msg_scan_->header.frame_id = "laser";
    msg_scan_->angle_min       = -M_PI;
    msg_scan_->angle_max       =  M_PI;
    msg_scan_->angle_increment = 2.0 * M_PI / NUM_BEAMS;
    msg_scan_->scan_time       = 1.0 / HZ_SCAN;
    msg_scan_->time_increment  = msg_scan_->scan_time / NUM_BEAMS;
    msg_scan_->range_min       = 0.1f;
    msg_scan_->range_max       = 30.0f;
    msg_scan_->ranges.resize(NUM_BEAMS, RANGE_VAL);
  }

  void init_cam()
  {
    msg_cam_ = std::make_shared<sensor_msgs::msg::CompressedImage>();
    msg_cam_->header.frame_id = "camera";
    msg_cam_->format          = "jpeg";
    msg_cam_->data.resize(JPEG_SIZE_B, 0x00);
    msg_cam_->data[0] = 0xFF;
    msg_cam_->data[1] = 0xD8;
    msg_cam_->data[2] = 0xFF;
  }

  void pub_cmd()
  {
    msg_cmd_->header.stamp = now();
    pub_cmd_->publish(*msg_cmd_);
    if (++cnt_cmd_ % 200 == 0) {
      RCLCPP_INFO(get_logger(), "/cmd_vel %lu msgs", cnt_cmd_);
    }
  }

  void pub_imu()
  {
    msg_imu_->header.stamp = now();
    pub_imu_->publish(*msg_imu_);
    if (++cnt_imu_ % 1000 == 0) {
      RCLCPP_INFO(get_logger(), "/imu %lu msgs", cnt_imu_);
    }
  }

  void pub_scan()
  {
    msg_scan_->header.stamp = now();
    pub_scan_->publish(*msg_scan_);
    if (++cnt_scan_ % 200 == 0) {
      RCLCPP_INFO(get_logger(), "/scan %lu msgs", cnt_scan_);
    }
  }

  void pub_cam()
  {
    msg_cam_->header.stamp = now();
    pub_cam_->publish(*msg_cam_);
    if (++cnt_cam_ % 150 == 0) {
      RCLCPP_INFO(get_logger(), "/image_raw/compressed %lu msgs", cnt_cam_);
    }
  }

  rclcpp::Publisher<geometry_msgs::msg::TwistStamped>::SharedPtr pub_cmd_;
  rclcpp::Publisher<sensor_msgs::msg::Imu>::SharedPtr        pub_imu_;
  rclcpp::Publisher<sensor_msgs::msg::LaserScan>::SharedPtr  pub_scan_;
  rclcpp::Publisher<sensor_msgs::msg::CompressedImage>::SharedPtr pub_cam_;

  rclcpp::TimerBase::SharedPtr timer_cmd_;
  rclcpp::TimerBase::SharedPtr timer_imu_;
  rclcpp::TimerBase::SharedPtr timer_scan_;
  rclcpp::TimerBase::SharedPtr timer_cam_;
  rclcpp::TimerBase::SharedPtr timer_shutdown_;

  geometry_msgs::msg::TwistStamped::SharedPtr  msg_cmd_;
  sensor_msgs::msg::Imu::SharedPtr             msg_imu_;
  sensor_msgs::msg::LaserScan::SharedPtr       msg_scan_;
  sensor_msgs::msg::CompressedImage::SharedPtr msg_cam_;

  uint64_t cnt_cmd_, cnt_imu_, cnt_scan_, cnt_cam_;
  double duration_s_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  auto args = rclcpp::remove_ros_arguments(argc, argv);
  double duration_s = 300.0;
  if (args.size() > 1) {
    duration_s = std::stod(args[1]);
  }
  auto node = std::make_shared<S5aPublisher>(duration_s);
  rclcpp::executors::MultiThreadedExecutor exec;
  exec.add_node(node);
  exec.spin();
  rclcpp::shutdown();
  return 0;
}
