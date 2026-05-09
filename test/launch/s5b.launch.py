from launch import LaunchDescription
from launch_ros.actions import Node
from launch.actions import GroupAction
from launch_ros.actions import PushRosNamespace


# S5-b: 로보택시
# /cmd_vel(20Hz) + /imu(200Hz) + /points 64ch(10Hz)
# + /camera/front/compressed(30Hz) + /camera/side/compressed(30Hz)
# + /depth/image_raw(30Hz)
def generate_launch_description():
    return LaunchDescription([
        Node(package='test', executable='s1_pub'),
        Node(package='test', executable='s2_pub'),
        Node(package='test', executable='s3_points_pub',
             arguments=['130000']),

        # 전방 카메라: /camera/front/compressed
        Node(package='test', executable='s4a_pub',
             remappings=[('/image_raw/compressed', '/camera/front/compressed')]),

        # 측면 카메라: /camera/side/compressed
        Node(package='test', executable='s4a_pub',
             remappings=[('/image_raw/compressed', '/camera/side/compressed')]),

        Node(package='test', executable='s4_image_pub',
             arguments=['640', '480', '16UC1']),

        # subscribers
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
