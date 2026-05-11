# ros2probe 실험 워크로드 시나리오

## 실험 개요

**목적**: ros2probe의 세 가지 특성 검증
- observer effect 없음 (ROS 2 participant를 추가하지 않음)
- discovery 영향 없음 (SPDP/SEDP 트래픽에 참여하지 않음)
- 낮은 CPU 오버헤드

**비교 대상**: ros2cli (ros2 topic), ros2 daemon, ros2 bag

**실험 환경**
- 기본: 노트북 2대 + 와이파이 공유기 유선랜(GbE, ~940 Mbps 실효) 연결
- 추가: Jetson, Raspberry Pi 추가 연결
- 확장: 무선(WiFi) 실험 병행

---

## 워크로드 시나리오 (공통)

본 실험의 워크로드는 ROS 2 무선 텔레오퍼레이션 및 실물 로봇 네트워크 선행 연구에서 사용된
실제 토픽 구성·메시지 주기·페이로드 크기를 차용한다.

시나리오는 **네트워크 현실 재현 구간**과 **처리량 한계 탐색 구간**으로 구분하며,
GbE(~940 Mbps 실효) 포화 여부를 각 항목에 명시한다.

---

### S1 — 원격 제어 (Teleoperation Command)

| 항목 | 값 |
|------|-----|
| 토픽 | `/cmd_vel` |
| 타입 | `geometry_msgs/Twist` |
| 주기 | 20 Hz (기본) / 50 Hz (상한) |
| CDR 페이로드 | ~48 B (float64 × 6) |
| 총 UDP 패킷 | ~200 B (RTPS 헤더 포함) |
| 추정 대역폭 | ~32 Kbps / ~80 Kbps |
| IP 단편화 | 없음 (단일 패킷) |
| RTPS DATA_FRAG | 없음 |
| 구간 분류 | **현실 재현** |

Nav2 Controller Server 기본값(20 Hz) 및 상한(50 Hz).

---

### S2 — IMU 스트림

| 항목 | 값 |
|------|-----|
| 토픽 | `/imu` |
| 타입 | `sensor_msgs/Imu` |
| 주기 | 200 Hz |
| CDR 페이로드 | ~320 B (quaternion + 공분산 행렬 3개 포함) |
| 총 UDP 패킷 | ~450 B |
| 추정 대역폭 | ~720 Kbps |
| IP 단편화 | 없음 (단일 패킷) |
| RTPS DATA_FRAG | 없음 |
| 구간 분류 | **현실 재현** |

저대역·고주기 센서의 대표. ROS 2 무선 통신 벤치마킹에서 널리 쓰이는 주기·크기 조합.

> **페이로드 산출 근거**: IMU CDR = header(8B) + orientation(32B) + orientation_covariance(72B)
> + angular_velocity(24B) + angular_velocity_covariance(72B) + linear_acceleration(24B)
> + linear_acceleration_covariance(72B) + frame_id(~4B) ≈ 320B CDR / ~450B 총 패킷

---

### S3 — LiDAR 스트림

실제 AMR·자율주행 플랫폼에서 채택되는 LiDAR 센서의 PointCloud2 출력 프로파일을 차용한다.
3단계 센서 계층으로 스윕하며, IP 단편화 → RTPS DATA_FRAG → 다수 fragment 처리를 단계별로 커버한다.

#### S3-a — 2D LiDAR

| 항목 | 값 |
|------|-----|
| 대상 센서 | Hokuyo UST-10LX, SICK TiM5xx, RPLIDAR A3 |
| 토픽 | `/scan` |
| 타입 | `sensor_msgs/LaserScan` |
| 주기 | 40 Hz |
| 페이로드 | ~4–9 KB (빔 수·인텐시티 포함 여부에 따라 상이) |
| 추정 대역폭 | ~3–29 Mbps |
| IP 단편화 | **발생** (MTU 1500 B 초과) |
| RTPS DATA_FRAG | 없음 |
| 구간 분류 | **현실 재현** |

실내 AMR, TurtleBot 계열 표준 구성. `ip_frag.rs` 재조립 경로 진입의 최소 단계.

#### S3-b — 3D LiDAR 16채널

| 항목 | 값 |
|------|-----|
| 대상 센서 | Velodyne VLP-16, Robosense RS-LiDAR-16 |
| 토픽 | `/points` |
| 타입 | `sensor_msgs/PointCloud2` |
| 주기 | 10 Hz |
| 페이로드 | ~660 KB (30,000 pts × 22 B/pt) |
| 추정 대역폭 | ~53 Mbps |
| IP 단편화 | **발생** |
| RTPS DATA_FRAG | **발생** (64 KB 초과) |
| 구간 분류 | **현실 재현** |

Clearpath Husky, Warehouse AMR, Navigation2 데모 대표 구성.
`RtpsProcessor` DATA_FRAG 재조립 부하 진입.

#### S3-c — 3D LiDAR 64/128채널

| 항목 | 값 |
|------|-----|
| 대상 센서 | Velodyne HDL-64E, Ouster OS1-128, Hesai Pandar64 |
| 토픽 | `/points` |
| 타입 | `sensor_msgs/PointCloud2` |
| 주기 | 10 Hz |
| 페이로드 | ~2–4 MB |
| 추정 대역폭 | ~160–320 Mbps |
| IP 단편화 | **발생** |
| RTPS DATA_FRAG | **발생** (다수 fragment) |
| 구간 분류 | **현실 재현** |

Autoware 실차 배포 및 nuScenes/KITTI 재생 워크로드 기준 프로파일.

---

### S4 — 영상 스트림

무선 텔레오퍼레이션과 인식 파이프라인에서 사용되는 카메라 구성을 차용한다.

#### S4-a — Compressed 원격 감시 영상 *(현실 재현)*

| 항목 | 값 |
|------|-----|
| 토픽 | `/image_raw/compressed` |
| 타입 | `sensor_msgs/CompressedImage` |
| 인코딩 | JPEG 품질 80%, 720p (1280×720) |
| 주기 | 30 Hz |
| 페이로드 | ~120–200 KB |
| 추정 대역폭 | ~29–48 Mbps |
| RTPS DATA_FRAG | **발생** |
| 구간 분류 | **현실 재현** |

`image_transport`를 통해 네트워크 구간에 실제로 흐르는 토픽 형태.
무선 텔레오퍼레이션 표준 영상 대역.

#### S4-b — Depth 카메라 스트림 *(현실 재현)*

| 항목 | 값 |
|------|-----|
| 토픽 | `/depth/image_raw` |
| 타입 | `sensor_msgs/Image` |
| 인코딩 | 16UC1, 640×480 |
| 주기 | 30 Hz |
| 페이로드 | ~614 KB (640 × 480 × 2 B) |
| 추정 대역폭 | ~148 Mbps |
| RTPS DATA_FRAG | **발생** |
| 구간 분류 | **현실 재현** |

Intel RealSense, Microsoft Azure Kinect 기반 실내 AMR 로컬라이제이션 표준 구성.

---

## 시나리오 요약표

| 시나리오 | 토픽 | 주기 | 페이로드 | 추정 대역폭 | IP 단편화 | DATA_FRAG | 분류 |
|----------|------|------|---------|------------|:--------:|:---------:|------|
| S1 | /cmd_vel | 20 Hz / 50 Hz | ~200 B | ~32 Kbps / ~80 Kbps | ✗ | ✗ | 현실 재현 |
| S2 | /imu | 200 Hz | ~450 B | ~720 Kbps | ✗ | ✗ | 현실 재현 |
| S3-a | /scan | 40 Hz | ~4–9 KB | ~3–29 Mbps | ✓ | ✗ | 현실 재현 |
| S3-b | /points | 10 Hz | ~660 KB | ~53 Mbps | ✓ | ✓ | 현실 재현 |
| S3-c | /points | 10 Hz | ~2–4 MB | ~160–320 Mbps | ✓ | ✓ | 현실 재현 |
| S4-a | /image_raw/compressed | 30 Hz | ~150 KB | ~36 Mbps | ✓ | ✓ | 현실 재현 |
| S4-b | /depth/image_raw | 30 Hz | ~614 KB | ~148 Mbps | ✓ | ✓ | 현실 재현 |
| S5-a | S1+S2+S3-a+S4-a | — | — | ~33–78 Mbps | ✓ | ✓ | 현실 재현 (실내 AMR) |
| S5-b | S1+S2+S3-d+S4-a×2+S4-b | — | — | ~367–565 Mbps | ✓ | ✓ | 현실 재현 (로보택시) |

---

## 복합 워크로드

### S5 — 현실적 복합 플랫폼 워크로드

단일 토픽 시나리오(S1–S4)와 달리, 실제 로봇 플랫폼에서 동시에 흐르는 토픽 조합을 재현한다.
ros2probe의 다중 GID 동시 처리 CPU 오버헤드를 플랫폼 클래스별로 검증한다.

#### S5-a — 실내 AMR

| 항목 | 값 |
|------|-----|
| 구성 | S1 (/cmd_vel, 20 Hz) + S2 (/imu, 200 Hz) + S3-a (/scan, 40 Hz) + S4-a (/image_raw/compressed, 30 Hz) |
| 활성 GID 수 | 4 |
| 총 추정 대역폭 | ~33–78 Mbps |
| 대표 플랫폼 | TurtleBot4, Clearpath Jackal (실내 배달·순찰 로봇) |
| 실험 목적 | 저~중대역폭 구간에서 GID 필터 맵·IP 단편화 재조립 동시 처리 부하 측정 |
| 구간 분류 | **현실 재현** |

#### S5-b — 고성능 자율주행 플랫폼 (로보택시)

| 항목 | 값 |
|------|-----|
| 구성 | S1 (/cmd_vel, 20 Hz) + S2 (/imu, 200 Hz) + S3-d (/points 64ch, 10 Hz) + S4-a × 2 (/image_raw/compressed 전방·측면, 30 Hz) + S4-b (/depth/image_raw, 30 Hz) |
| 활성 GID 수 | 6 |
| 총 추정 대역폭 | ~367–565 Mbps |
| 대표 플랫폼 | Autoware 실차, Apollo 배포 플랫폼 |
| 실험 목적 | 고대역폭·다중 DATA_FRAG 동시 처리 시 RtpsProcessor 및 eBPF 파이프라인 부하 측정 |
| 구간 분류 | **현실 재현** (GbE 여유 ~375–573 Mbps 잔여) |

> **플랫폼 역할**: S3-d publisher는 Jetson 또는 노트북 담당. S4-b publisher는 노트북 담당 (RPi는 CPU 한계).

---

## 측정 조건

- **QoS**: S1–S3는 BEST_EFFORT / RELIABLE 양쪽 측정, S4는 BEST_EFFORT 고정
- **측정 구간**: 참여자 discovery 완료 후 30초–90초 steady-state 구간
- **플랫폼 역할**: 고대역폭 publisher(S3-d, S4-b)는 Jetson 또는 노트북 담당 (RPi는 CPU 한계로 publisher 불가)
