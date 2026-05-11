#include <chrono>
#include <cstdint>
#include <memory>

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/point_cloud2.hpp>
#include <sensor_msgs/msg/point_field.hpp>

// Velodyne 드라이버 호환 레이아웃 (22 B/pt)
// x(4) y(4) z(4) intensity(4) ring(2) time(4)
static constexpr uint32_t POINT_STEP = 22;
static constexpr double   HZ         = 10.0;

// 시나리오별 기본 포인트 수
// S3-b: 30000, S3-c: 130000
static constexpr uint32_t DEFAULT_NUM_POINTS = 30000;

class S3PointsPublisher : public rclcpp::Node
{
public:
  explicit S3PointsPublisher(uint32_t num_points, uint64_t max_count)
  : Node("s3_points_publisher"), pub_count_(0), max_count_(max_count)
  {
    rclcpp::QoS qos(1);
    qos.best_effort();
    pub_ = create_publisher<sensor_msgs::msg::PointCloud2>("/points", qos);

    // 메시지 초기화 시 한 번만 할당
    msg_ = std::make_shared<sensor_msgs::msg::PointCloud2>();
    msg_->header.frame_id = "velodyne";
    msg_->height          = 1;
    msg_->width           = num_points;
    msg_->point_step      = POINT_STEP;
    msg_->row_step        = num_points * POINT_STEP;
    msg_->is_dense        = true;
    msg_->is_bigendian    = false;

    // 필드 정의 (Velodyne VLP-16/32C/HDL-64E 공통)
    auto make_field = [](const std::string & name, uint32_t offset,
                         uint8_t datatype, uint32_t count)
    {
      sensor_msgs::msg::PointField f;
      f.name     = name;
      f.offset   = offset;
      f.datatype = datatype;
      f.count    = count;
      return f;
    };
    msg_->fields = {
      make_field("x",         0,  sensor_msgs::msg::PointField::FLOAT32, 1),
      make_field("y",         4,  sensor_msgs::msg::PointField::FLOAT32, 1),
      make_field("z",         8,  sensor_msgs::msg::PointField::FLOAT32, 1),
      make_field("intensity", 12, sensor_msgs::msg::PointField::FLOAT32, 1),
      make_field("ring",      16, sensor_msgs::msg::PointField::UINT16,  1),
      make_field("time",      18, sensor_msgs::msg::PointField::FLOAT32, 1),
    };

    // data 배열 초기화 후 재사용 (resize는 여기서만)
    msg_->data.resize(num_points * POINT_STEP, 0);

    double payload_kb = num_points * POINT_STEP / 1024.0;
    RCLCPP_INFO(get_logger(),
      "S3 points publisher started: %.1f Hz, %u pts, %.1f KB/msg, max %lu msgs, BEST_EFFORT",
      HZ, num_points, payload_kb, max_count_);

    auto period = std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::duration<double>(1.0 / HZ));
    timer_ = create_wall_timer(period, [this]() { timer_cb(); });
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
    if (pub_count_ % 50 == 0) {
      RCLCPP_INFO(get_logger(), "published %lu msgs", pub_count_);
    }
  }

  rclcpp::Publisher<sensor_msgs::msg::PointCloud2>::SharedPtr pub_;
  rclcpp::TimerBase::SharedPtr timer_;
  sensor_msgs::msg::PointCloud2::SharedPtr msg_;
  uint64_t pub_count_;
  uint64_t max_count_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  auto args = rclcpp::remove_ros_arguments(argc, argv);

  uint32_t num_points = DEFAULT_NUM_POINTS;
  if (args.size() > 1) {
    num_points = static_cast<uint32_t>(std::stoul(args[1]));
  }
  uint64_t max_count = static_cast<uint64_t>(HZ * 60.0);
  if (args.size() > 2) {
    max_count = std::stoull(args[2]);
  }

  auto node = std::make_shared<S3PointsPublisher>(num_points, max_count);

  rclcpp::executors::MultiThreadedExecutor exec;
  exec.add_node(node);
  exec.spin();

  rclcpp::shutdown();
  return 0;
}
