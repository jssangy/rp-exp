from launch import LaunchDescription
from launch_ros.actions import Node


# S5-a: 실내 AMR
# /cmd_vel(20Hz) + /imu(200Hz) + /scan(40Hz) + /image_raw/compressed(30Hz)
def generate_launch_description():
    return LaunchDescription([
        Node(package='test', executable='s1_pub'),
        Node(package='test', executable='s2_pub'),
        Node(package='test', executable='s3a_pub'),
        Node(package='test', executable='s4a_pub'),

        Node(package='test', executable='s1_sub'),
        Node(package='test', executable='s2_sub'),
        Node(package='test', executable='s3a_sub'),
        Node(package='test', executable='s4a_sub'),
    ])
