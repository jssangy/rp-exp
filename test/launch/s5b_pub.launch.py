from launch import LaunchDescription
from launch_ros.actions import Node


# S5-b pub: high-bandwidth autonomous driving
# /cmd_vel + /imu + /points/front 64ch + /points/rear 16ch
# + front/left/right/rear compressed cameras + /depth/image_raw
def generate_launch_description():
    return LaunchDescription([
        Node(package='test', executable='s1_pub', name='cmd_vel_publisher'),
        Node(package='test', executable='s2_pub', name='imu_publisher'),
        Node(package='test', executable='s3_points_pub',
             name='points_front_publisher',
             arguments=['130000'],
             remappings=[('/points', '/points/front')]),
        Node(package='test', executable='s3_points_pub',
             name='points_rear_publisher',
             arguments=['30000'],
             remappings=[('/points', '/points/rear')]),
        Node(package='test', executable='s4a_pub',
             name='camera_front_publisher',
             remappings=[('/image_raw/compressed', '/camera/front/compressed')]),
        Node(package='test', executable='s4a_pub',
             name='camera_left_publisher',
             remappings=[('/image_raw/compressed', '/camera/left/compressed')]),
        Node(package='test', executable='s4a_pub',
             name='camera_right_publisher',
             remappings=[('/image_raw/compressed', '/camera/right/compressed')]),
        Node(package='test', executable='s4a_pub',
             name='camera_rear_publisher',
             remappings=[('/image_raw/compressed', '/camera/rear/compressed')]),
        Node(package='test', executable='s4_image_pub',
             name='depth_publisher',
             arguments=['640', '480', '16UC1']),
    ])
