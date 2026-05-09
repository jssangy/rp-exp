from launch import LaunchDescription
from launch_ros.actions import Node


# S5-b sub: 로보택시
# /cmd_vel + /imu + /points + /camera/front/compressed + /camera/side/compressed
# + /depth/image_raw
def generate_launch_description():
    return LaunchDescription([
        Node(package='test', executable='s1_sub'),
        Node(package='test', executable='s2_sub'),
        Node(package='test', executable='s3_points_sub'),
        Node(package='test', executable='s4a_sub',
             remappings=[('/image_raw/compressed', '/camera/front/compressed')]),
        Node(package='test', executable='s4a_sub',
             remappings=[('/image_raw/compressed', '/camera/side/compressed')]),
        Node(package='test', executable='s4_image_sub',
             arguments=['/depth/image_raw']),
    ])
