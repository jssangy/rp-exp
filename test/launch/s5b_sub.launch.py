from launch import LaunchDescription
from launch_ros.actions import Node


# S5-b sub: high-bandwidth autonomous driving
# /cmd_vel + /imu + /points/front + /points/rear
# + front/left/right/rear compressed cameras + /depth/image_raw
def generate_launch_description():
    return LaunchDescription([
        Node(package='test', executable='s1_sub',
             name='cmd_vel_subscriber', output='screen', emulate_tty=True),
        Node(package='test', executable='s2_sub',
             name='imu_subscriber', output='screen', emulate_tty=True),
        Node(package='test', executable='s3_points_sub',
             name='points_front_subscriber', output='screen', emulate_tty=True,
             remappings=[('/points', '/points/front')]),
        Node(package='test', executable='s3_points_sub',
             name='points_rear_subscriber', output='screen', emulate_tty=True,
             remappings=[('/points', '/points/rear')]),
        Node(package='test', executable='s4a_sub',
             name='camera_front_subscriber',
             output='screen', emulate_tty=True,
             remappings=[('/image_raw/compressed', '/camera/front/compressed')]),
        Node(package='test', executable='s4a_sub',
             name='camera_left_subscriber',
             output='screen', emulate_tty=True,
             remappings=[('/image_raw/compressed', '/camera/left/compressed')]),
        Node(package='test', executable='s4a_sub',
             name='camera_right_subscriber',
             output='screen', emulate_tty=True,
             remappings=[('/image_raw/compressed', '/camera/right/compressed')]),
        Node(package='test', executable='s4a_sub',
             name='camera_rear_subscriber',
             output='screen', emulate_tty=True,
             remappings=[('/image_raw/compressed', '/camera/rear/compressed')]),
        Node(package='test', executable='s4_image_sub',
             name='depth_subscriber',
             output='screen', emulate_tty=True,
             arguments=['/depth/image_raw']),
    ])
