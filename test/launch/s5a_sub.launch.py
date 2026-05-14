from launch import LaunchDescription
from launch_ros.actions import Node


# S5-a sub: 실내 AMR
# /cmd_vel + /imu + /scan + /image_raw/compressed
def generate_launch_description():
    return LaunchDescription([
        Node(package='test', executable='s1_sub', output='screen', emulate_tty=True),
        Node(package='test', executable='s2_sub', output='screen', emulate_tty=True),
        Node(package='test', executable='s3a_sub', output='screen', emulate_tty=True),
        Node(package='test', executable='s4a_sub', output='screen', emulate_tty=True),
    ])
