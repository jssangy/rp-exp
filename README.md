# ros2probe 검증 실험 워크로드 노드

ros2probe의 observer effect, discovery 영향, CPU 오버헤드를 검증하기 위한 pub/sub 워크로드 노드 모음.

## 빌드

```bash
source /opt/ros/humble/setup.bash
colcon build --packages-select test
source install/setup.bash
```

## 실험 전 환경 설정

```bash
# CPU frequency governor 고정
sudo cpupower frequency-set -g performance

# ros2 daemon 비활성화
ros2 daemon stop

# rmw 명시
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp

# 실험별 도메인 격리 (값은 실험마다 다르게)
export ROS_DOMAIN_ID=10
```

---

## 시나리오별 실행 명령어

> publisher는 송신 머신, subscriber는 수신 머신에서 실행.

### S1 — 원격 제어 (`/cmd_vel`, `geometry_msgs/Twist`)

| 항목 | 값 |
|------|-----|
| 주기 | 20 Hz (기본) / 50 Hz (상한) |
| 페이로드 | ~200 B |
| 대역폭 | ~32 Kbps / ~80 Kbps |

```bash
# publisher — 기본 20 Hz
ros2 run test s1_pub

# publisher — 상한 50 Hz
ros2 run test s1_pub 50.0

# subscriber
ros2 run test s1_sub
```

---

### S2 — IMU 스트림 (`/imu`, `sensor_msgs/Imu`)

| 항목 | 값 |
|------|-----|
| 주기 | 200 Hz |
| 페이로드 | ~450 B |
| 대역폭 | ~720 Kbps |

```bash
# publisher
ros2 run test s2_pub

# subscriber
ros2 run test s2_sub
```

---

### S3-a — 2D LiDAR (`/scan`, `sensor_msgs/LaserScan`)

| 항목 | 값 |
|------|-----|
| 주기 | 40 Hz |
| 페이로드 | ~4 KB (1080 beams) |
| 대역폭 | ~3–29 Mbps |
| IP 단편화 | 발생 |

```bash
# publisher
ros2 run test s3a_pub

# subscriber
ros2 run test s3a_sub
```

---

### S3-b — 3D LiDAR 16ch (`/points`, `sensor_msgs/PointCloud2`)

| 항목 | 값 |
|------|-----|
| 주기 | 10 Hz |
| 페이로드 | ~660 KB (30,000 pts × 22 B) |
| 대역폭 | ~53 Mbps |
| IP 단편화 / DATA_FRAG | 발생 |

```bash
# publisher
ros2 run test s3_points_pub 30000

# subscriber
ros2 run test s3_points_sub
```

---

### S3-c — 3D LiDAR 32ch (`/points`, `sensor_msgs/PointCloud2`)

| 항목 | 값 |
|------|-----|
| 주기 | 10 Hz |
| 페이로드 | ~1.3 MB (60,000 pts × 22 B) |
| 대역폭 | ~106 Mbps |

```bash
# publisher
ros2 run test s3_points_pub 60000

# subscriber
ros2 run test s3_points_sub
```

---

### S3-d — 3D LiDAR 64/128ch (`/points`, `sensor_msgs/PointCloud2`)

| 항목 | 값 |
|------|-----|
| 주기 | 10 Hz (기본) / 20 Hz (한계 탐색) |
| 페이로드 | ~2.8 MB (130,000 pts × 22 B) |
| 대역폭 | ~160–320 Mbps @ 10 Hz |

```bash
# publisher — 10 Hz (현실 재현)
ros2 run test s3_points_pub 130000

# subscriber
ros2 run test s3_points_sub
```

---

### S4-a — Compressed 카메라 (`/image_raw/compressed`, `sensor_msgs/CompressedImage`)

| 항목 | 값 |
|------|-----|
| 주기 | 30 Hz |
| 페이로드 | ~150 KB (JPEG 720p) |
| 대역폭 | ~36 Mbps |

```bash
# publisher
ros2 run test s4a_pub

# subscriber
ros2 run test s4a_sub
```

---

### S4-b — Depth 카메라 (`/depth/image_raw`, `sensor_msgs/Image`)

| 항목 | 값 |
|------|-----|
| 주기 | 30 Hz |
| 페이로드 | ~614 KB (640×480, 16UC1) |
| 대역폭 | ~148 Mbps |

```bash
# publisher
ros2 run test s4_image_pub 640 480 16UC1

# subscriber
ros2 run test s4_image_sub /depth/image_raw
```

---

### S4-c — Raw RGB 720p (`/image_raw`, `sensor_msgs/Image`) ⚠️ 한계 탐색

| 항목 | 값 |
|------|-----|
| 주기 | 30 Hz |
| 페이로드 | ~2.76 MB (1280×720, rgb8) |
| 대역폭 | ~664 Mbps (GbE 한계 근접) |

```bash
# publisher
ros2 run test s4_image_pub 1280 720 rgb8

# subscriber
ros2 run test s4_image_sub /image_raw
```

---

### S4-d — Raw RGB 1080p (`/image_raw`, `sensor_msgs/Image`) ⚠️ 한계 탐색

| 항목 | 값 |
|------|-----|
| 주기 | 30 Hz |
| 페이로드 | ~6.22 MB (1920×1080, rgb8) |
| 대역폭 | ~1.49 Gbps (GbE 초과) |

```bash
# publisher
ros2 run test s4_image_pub 1920 1080 rgb8

# subscriber
ros2 run test s4_image_sub /image_raw
```

---

### S5-a — 실내 AMR 복합 워크로드

| 항목 | 값 |
|------|-----|
| 구성 | /cmd_vel (20 Hz) + /imu (200 Hz) + /scan (40 Hz) + /image_raw/compressed (30 Hz) |
| GID 수 | 4 |
| 대역폭 | ~33–78 Mbps |
| 대표 플랫폼 | TurtleBot4, Clearpath Jackal |

```bash
# publisher
ros2 run test s5a_pub

# subscriber
ros2 run test s5a_sub
```

---

### S5-b — 고성능 자율주행 플랫폼 복합 워크로드 (로보택시)

| 항목 | 값 |
|------|-----|
| 구성 | /cmd_vel (20 Hz) + /imu (200 Hz) + /points 64ch (10 Hz) + /camera/front/compressed (30 Hz) + /camera/side/compressed (30 Hz) + /depth/image_raw (30 Hz) |
| GID 수 | 6 |
| 대역폭 | ~367–565 Mbps |
| 대표 플랫폼 | Autoware, Apollo |

```bash
# publisher — S3-d 포함으로 Jetson 또는 노트북 담당 권장
ros2 run test s5b_pub

# subscriber
ros2 run test s5b_sub
```

---

## 노드 목록

| 바이너리 | 역할 | 토픽 |
|---------|------|------|
| `s1_pub` / `s1_sub` | S1 pub/sub | `/cmd_vel` |
| `s2_pub` / `s2_sub` | S2 pub/sub | `/imu` |
| `s3a_pub` / `s3a_sub` | S3-a pub/sub | `/scan` |
| `s3_points_pub` / `s3_points_sub` | S3-b/c/d pub/sub | `/points` |
| `s4a_pub` / `s4a_sub` | S4-a pub/sub | `/image_raw/compressed` |
| `s4_image_pub` / `s4_image_sub` | S4-b/c/d pub/sub | `/depth/image_raw`, `/image_raw` |
| `s5a_pub` / `s5a_sub` | S5-a 복합 pub/sub | 4개 토픽 |
| `s5b_pub` / `s5b_sub` | S5-b 복합 pub/sub | 6개 토픽 |
