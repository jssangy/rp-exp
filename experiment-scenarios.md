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
| 주기 | 100 Hz |
| CDR 페이로드 | ~48 B (float64 × 6) |
| 총 UDP 패킷 | ~200 B (RTPS 헤더 포함) |
| 추정 대역폭 | ~160 Kbps |
| IP 단편화 | 없음 (단일 패킷) |
| RTPS DATA_FRAG | 없음 |
| 구간 분류 | **현실 재현** |

TurtleBot 계열 ROS 2 텔레오퍼레이션 데모의 표준 제어 토픽 구성을 따른다.

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
4단계 센서 계층으로 스윕하며, IP 단편화 → RTPS DATA_FRAG → 커널 버퍼 포화를 단계별로 커버한다.

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
| 페이로드 | ~480 KB (30,000 pts × 16 B/pt) |
| 추정 대역폭 | ~38 Mbps |
| IP 단편화 | **발생** |
| RTPS DATA_FRAG | **발생** (64 KB 초과) |
| 구간 분류 | **현실 재현** |

Clearpath Husky, Warehouse AMR, Navigation2 데모 대표 구성.
`RtpsProcessor` DATA_FRAG 재조립 부하 진입.

#### S3-c — 3D LiDAR 32채널

| 항목 | 값 |
|------|-----|
| 대상 센서 | Velodyne VLP-32C, Ouster OS1-32 |
| 토픽 | `/points` |
| 타입 | `sensor_msgs/PointCloud2` |
| 주기 | 10 Hz |
| 페이로드 | ~960 KB (60,000 pts × 16 B/pt) |
| 추정 대역폭 | ~77 Mbps |
| IP 단편화 | **발생** |
| RTPS DATA_FRAG | **발생** |
| 구간 분류 | **현실 재현** |

중급 AMR, 로보택시 프로토타입. DATA_FRAG fragment 수 증가로 `MAX_FRAGMENT_FLOWS` 맵 활용률 상승.

#### S3-d — 3D LiDAR 64/128채널

| 항목 | 값 |
|------|-----|
| 대상 센서 | Velodyne HDL-64E, Ouster OS1-128, Hesai Pandar64 |
| 토픽 | `/points` |
| 타입 | `sensor_msgs/PointCloud2` |
| 주기 | **10 Hz** (기본) / 20 Hz (한계 탐색) |
| 페이로드 | ~2–4 MB @ 10 Hz / ~2–8 MB @ 20 Hz |
| 추정 대역폭 | ~160–320 Mbps @ 10 Hz / **~640 Mbps–1.28 Gbps @ 20 Hz** |
| IP 단편화 | **발생** |
| RTPS DATA_FRAG | **발생** (다수 fragment) |
| 구간 분류 | 10 Hz: **현실 재현** / 20 Hz: **처리량 한계 탐색** |

Autoware 실차 배포 및 nuScenes/KITTI 재생 워크로드 기준 프로파일.
20 Hz 최대 페이로드(~8 MB)는 GbE 초과 → 의도적 포화 구간.

---

### S4 — 영상 스트림

무선 텔레오퍼레이션과 인식 파이프라인에서 사용되는 카메라 구성을 차용한다.
네트워크 구간에서의 현실 재현 여부에 따라 두 계층으로 구분한다.

> **배경**: Raw 이미지는 실제 배포에서 intra-process/SHM으로 처리되거나 `image_transport`
> 압축 후 전송된다. Raw를 그대로 네트워크로 보내는 경우는 처리량 한계 탐색 목적으로만 사용한다.

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

#### S4-c — Raw RGB 720p *(처리량 한계 탐색)*

| 항목 | 값 |
|------|-----|
| 토픽 | `/image_raw` |
| 타입 | `sensor_msgs/Image` |
| 인코딩 | rgb8, 1280×720 |
| 주기 | 30 Hz |
| 페이로드 | ~2.76 MB (1280 × 720 × 3 B) |
| 추정 대역폭 | ~664 Mbps |
| RTPS DATA_FRAG | **발생** (다수 fragment) |
| 구간 분류 | **처리량 한계 탐색** (GbE 한계 근접) |

ros2probe `RtpsProcessor` DATA_FRAG 재조립 부하를 의도적으로 탐색하기 위한 stress 조건.

#### S4-d — Raw RGB 1080p *(처리량 한계 탐색)*

| 항목 | 값 |
|------|-----|
| 토픽 | `/image_raw` |
| 타입 | `sensor_msgs/Image` |
| 인코딩 | rgb8, 1920×1080 |
| 주기 | 30 Hz |
| 페이로드 | ~6.22 MB (1920 × 1080 × 3 B) |
| 추정 대역폭 | **~1.49 Gbps (GbE 초과)** |
| RTPS DATA_FRAG | **발생** (매우 다수 fragment) |
| 구간 분류 | **처리량 한계 탐색** (GbE 포화, 패킷 드롭 예상) |

Autoware 전면 카메라 전처리 입력 기준 프로파일.
GbE 포화로 인한 패킷 드롭·DATA_FRAG 불완전 재조립 경계 조건 관찰 목적.

---

## 시나리오 요약표

| 시나리오 | 토픽 | 주기 | 페이로드 | 추정 대역폭 | IP 단편화 | DATA_FRAG | 분류 |
|----------|------|------|---------|------------|:--------:|:---------:|------|
| S1 | /cmd_vel | 100 Hz | ~200 B | ~160 Kbps | ✗ | ✗ | 현실 재현 |
| S2 | /imu | 200 Hz | ~450 B | ~720 Kbps | ✗ | ✗ | 현실 재현 |
| S3-a | /scan | 40 Hz | ~4–9 KB | ~3–29 Mbps | ✓ | ✗ | 현실 재현 |
| S3-b | /points | 10 Hz | ~480 KB | ~38 Mbps | ✓ | ✓ | 현실 재현 |
| S3-c | /points | 10 Hz | ~960 KB | ~77 Mbps | ✓ | ✓ | 현실 재현 |
| S3-d | /points | 10 Hz | ~2–4 MB | ~160–320 Mbps | ✓ | ✓ | 현실 재현 |
| S3-d | /points | 20 Hz | ~2–8 MB | ~640M–1.28 Gbps | ✓ | ✓ | **한계 탐색** |
| S4-a | /image_raw/compressed | 30 Hz | ~150 KB | ~36 Mbps | ✓ | ✓ | 현실 재현 |
| S4-b | /depth/image_raw | 30 Hz | ~614 KB | ~148 Mbps | ✓ | ✓ | 현실 재현 |
| S4-c | /image_raw (720p) | 30 Hz | ~2.76 MB | ~664 Mbps | ✓ | ✓ | **한계 탐색** |
| S4-d | /image_raw (1080p) | 30 Hz | ~6.22 MB | **~1.49 Gbps** | ✓ | ✓ | **한계 탐색** |

---

## 복합 워크로드

### S5 — 현실적 AMR 복합 워크로드

실제 로봇은 단일 토픽만 발행하지 않는다.
다중 GID 동시 처리 시 ros2probe CPU 오버헤드를 검증하기 위한 복합 시나리오.

| 구성 | S1 (/cmd_vel, 100 Hz) + S2 (/imu, 200 Hz) + S3-a (/scan, 40 Hz) |
|------|------------------------------------------------------------------|
| 총 추정 대역폭 | ~30 Mbps |
| 실험 목적 | 다중 GID 동시 처리 시 eBPF GID 필터 맵 및 RtpsProcessor 부하 측정 |
| 구간 분류 | **현실 재현** |

---

## 측정 조건

- **QoS**: S1–S3는 BEST_EFFORT / RELIABLE 양쪽 측정, S4는 BEST_EFFORT 고정
- **측정 구간**: 참여자 discovery 완료 후 30초–90초 steady-state 구간
- **플랫폼 역할**: 고대역폭 publisher(S3-d, S4-c/d)는 Jetson 또는 노트북 담당 (RPi는 CPU 한계로 publisher 불가)
