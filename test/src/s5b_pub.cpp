#include <chrono>
#include <cmath>
#include <cstdint>
#include <memory>

#include <rclcpp/rclcpp.hpp>
#include <geometry_msgs/msg/twist.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>
#include <sensor_msgs/msg/imu.hpp>
#include <sensor_msgs/msg/image.hpp>
#include <sensor_msgs/msg/point_cloud2.hpp>
#include <sensor_msgs/msg/point_field.hpp>

// S5-b: 로보택시 — /cmd_vel(20Hz) + /imu(200Hz) + /points 64ch(10Hz)
//                 + /camera/front/compressed(30Hz) + /camera/side/compressed(30Hz)
//                 + /depth/image_raw(30Hz)
static constexpr double   HZ_CMD        = 20.0;
static constexpr double   HZ_IMU        = 200.0;
static constexpr double   HZ_POINTS     = 10.0;
static constexpr double   HZ_CAM        = 30.0;
static constexpr uint32_t NUM_POINTS    = 130000;   // 64ch ~2.8 MB
static constexpr uint32_t POINT_STEP    = 22;
static constexpr uint32_t JPEG_SIZE_B   = 150 * 1024;
static constexpr uint32_t DEPTH_W       = 640;
static constexpr uint32_t DEPTH_H       = 480;

class S5bPublisher : public rclcpp::Node
{
public:
  S5bPublisher()
  : Node("s5b_publisher"),
    cnt_cmd_(0), cnt_imu_(0), cnt_pts_(0), cnt_front_(0), cnt_side_(0), cnt_depth_(0)
  {
    rclcpp::QoS qos(1);
    qos.best_effort();

    pub_cmd_   = create_publisher<geometry_msgs::msg::Twist>("/cmd_vel", qos);
    pub_imu_   = create_publisher<sensor_msgs::msg::Imu>("/imu", qos);
    pub_pts_   = create_publisher<sensor_msgs::msg::PointCloud2>("/points", qos);
    pub_front_ = create_publisher<sensor_msgs::msg::CompressedImage>("/camera/front/compressed", qos);
    pub_side_  = create_publisher<sensor_msgs::msg::CompressedImage>("/camera/side/compressed", qos);
    pub_depth_ = create_publisher<sensor_msgs::msg::Image>("/depth/image_raw", qos);

    init_cmd();
    init_imu();
    init_points();
    init_cam(msg_front_, "camera_front");
    init_cam(msg_side_,  "camera_side");
    init_depth();

    auto make_timer = [this](double hz, auto cb) {
      auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::duration<double>(1.0 / hz));
      return create_wall_timer(ns, cb);
    };

    timer_cmd_   = make_timer(HZ_CMD,    [this]() { pub_cmd(); });
    timer_imu_   = make_timer(HZ_IMU,    [this]() { pub_imu(); });
    timer_pts_   = make_timer(HZ_POINTS, [this]() { pub_pts(); });
    timer_front_ = make_timer(HZ_CAM,    [this]() { pub_front(); });
    timer_side_  = make_timer(HZ_CAM,    [this]() { pub_side(); });
    timer_depth_ = make_timer(HZ_CAM,    [this]() { pub_depth(); });

    RCLCPP_INFO(get_logger(),
      "S5-b publisher started (로보택시): "
      "/cmd_vel %.0fHz | /imu %.0fHz | /points %upts %.0fHz | "
      "front/side compressed %.0fHz | /depth/image_raw %.0fHz",
      HZ_CMD, HZ_IMU, NUM_POINTS, HZ_POINTS, HZ_CAM, HZ_CAM);
  }

private:
  void init_cmd()
  {
    msg_cmd_ = std::make_shared<geometry_msgs::msg::Twist>();
    msg_cmd_->linear.x  = 0.5;
    msg_cmd_->angular.z = 0.3;
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

  void init_points()
  {
    msg_pts_ = std::make_shared<sensor_msgs::msg::PointCloud2>();
    msg_pts_->header.frame_id = "velodyne";
    msg_pts_->height          = 1;
    msg_pts_->width           = NUM_POINTS;
    msg_pts_->point_step      = POINT_STEP;
    msg_pts_->row_step        = NUM_POINTS * POINT_STEP;
    msg_pts_->is_dense        = true;
    msg_pts_->is_bigendian    = false;

    auto make_field = [](const std::string & name, uint32_t offset,
                         uint8_t datatype, uint32_t count)
    {
      sensor_msgs::msg::PointField f;
      f.name = name; f.offset = offset; f.datatype = datatype; f.count = count;
      return f;
    };
    msg_pts_->fields = {
      make_field("x",         0,  sensor_msgs::msg::PointField::FLOAT32, 1),
      make_field("y",         4,  sensor_msgs::msg::PointField::FLOAT32, 1),
      make_field("z",         8,  sensor_msgs::msg::PointField::FLOAT32, 1),
      make_field("intensity", 12, sensor_msgs::msg::PointField::FLOAT32, 1),
      make_field("ring",      16, sensor_msgs::msg::PointField::UINT16,  1),
      make_field("time",      18, sensor_msgs::msg::PointField::FLOAT32, 1),
    };
    msg_pts_->data.resize(NUM_POINTS * POINT_STEP, 0);
  }

  void init_cam(sensor_msgs::msg::CompressedImage::SharedPtr & msg,
                const std::string & frame_id)
  {
    msg = std::make_shared<sensor_msgs::msg::CompressedImage>();
    msg->header.frame_id = frame_id;
    msg->format          = "jpeg";
    msg->data.resize(JPEG_SIZE_B, 0x00);
    msg->data[0] = 0xFF;
    msg->data[1] = 0xD8;
    msg->data[2] = 0xFF;
  }

  void init_depth()
  {
    msg_depth_ = std::make_shared<sensor_msgs::msg::Image>();
    msg_depth_->header.frame_id = "depth_camera";
    msg_depth_->width           = DEPTH_W;
    msg_depth_->height          = DEPTH_H;
    msg_depth_->encoding        = "16UC1";
    msg_depth_->is_bigendian    = false;
    msg_depth_->step            = DEPTH_W * 2;
    msg_depth_->data.resize(DEPTH_H * DEPTH_W * 2, 0);
  }

  void pub_cmd()
  {
    pub_cmd_->publish(*msg_cmd_);
    if (++cnt_cmd_ % 200 == 0) { RCLCPP_INFO(get_logger(), "/cmd_vel %lu msgs", cnt_cmd_); }
  }

  void pub_imu()
  {
    msg_imu_->header.stamp = now();
    pub_imu_->publish(*msg_imu_);
    if (++cnt_imu_ % 1000 == 0) { RCLCPP_INFO(get_logger(), "/imu %lu msgs", cnt_imu_); }
  }

  void pub_pts()
  {
    msg_pts_->header.stamp = now();
    pub_pts_->publish(*msg_pts_);
    if (++cnt_pts_ % 50 == 0) { RCLCPP_INFO(get_logger(), "/points %lu msgs", cnt_pts_); }
  }

  void pub_front()
  {
    msg_front_->header.stamp = now();
    pub_front_->publish(*msg_front_);
    if (++cnt_front_ % 150 == 0) { RCLCPP_INFO(get_logger(), "/camera/front %lu msgs", cnt_front_); }
  }

  void pub_side()
  {
    msg_side_->header.stamp = now();
    pub_side_->publish(*msg_side_);
    if (++cnt_side_ % 150 == 0) { RCLCPP_INFO(get_logger(), "/camera/side %lu msgs", cnt_side_); }
  }

  void pub_depth()
  {
    msg_depth_->header.stamp = now();
    pub_depth_->publish(*msg_depth_);
    if (++cnt_depth_ % 150 == 0) { RCLCPP_INFO(get_logger(), "/depth/image_raw %lu msgs", cnt_depth_); }
  }

  rclcpp::Publisher<geometry_msgs::msg::Twist>::SharedPtr      pub_cmd_;
  rclcpp::Publisher<sensor_msgs::msg::Imu>::SharedPtr          pub_imu_;
  rclcpp::Publisher<sensor_msgs::msg::PointCloud2>::SharedPtr  pub_pts_;
  rclcpp::Publisher<sensor_msgs::msg::CompressedImage>::SharedPtr pub_front_;
  rclcpp::Publisher<sensor_msgs::msg::CompressedImage>::SharedPtr pub_side_;
  rclcpp::Publisher<sensor_msgs::msg::Image>::SharedPtr        pub_depth_;

  rclcpp::TimerBase::SharedPtr timer_cmd_, timer_imu_, timer_pts_;
  rclcpp::TimerBase::SharedPtr timer_front_, timer_side_, timer_depth_;

  geometry_msgs::msg::Twist::SharedPtr         msg_cmd_;
  sensor_msgs::msg::Imu::SharedPtr             msg_imu_;
  sensor_msgs::msg::PointCloud2::SharedPtr     msg_pts_;
  sensor_msgs::msg::CompressedImage::SharedPtr msg_front_;
  sensor_msgs::msg::CompressedImage::SharedPtr msg_side_;
  sensor_msgs::msg::Image::SharedPtr           msg_depth_;

  uint64_t cnt_cmd_, cnt_imu_, cnt_pts_, cnt_front_, cnt_side_, cnt_depth_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  auto node = std::make_shared<S5bPublisher>();
  rclcpp::executors::MultiThreadedExecutor exec;
  exec.add_node(node);
  exec.spin();
  rclcpp::shutdown();
  return 0;
}
