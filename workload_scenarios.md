# 공통 워크로드 설정

---

## 1) 워크로드 코드 구현 규칙 (기본 규칙)

| # | 규칙 | 이유/목적 |
|---|---|---|
| 1 | C++ 전용 (Python 금지) | 런타임 오버헤드 제거 |
| 2 | `MultiThreadedExecutor` 사용 (pub/sub 콜백과 메시지 처리 스레드 분리) | 콜백 블로킹이 타이머 정확도에 영향 안 주도록 |
| 3 | 메시지 객체 재사용 (루프 내 재할당 금지, 참조·복사만 허용) | allocator 개입 차단 |
| 4 | QoS: `BEST_EFFORT` + `KEEP_LAST(1)` | 재전송·큐 효과 제거 |

---

## 2) 공통 실험 환경/운영 설정 요약

| 구분 | 설정/명령 | 핵심 포인트(이유/주의) |
|---|---|---|
| 시스템 환경 | CPU frequency governor → `performance` 고정<br>`cpupower frequency-set -g performance` | 기본 정책(`schedutil`)은 부하에 따라 클럭 변동 → CPU 오버헤드 측정 왜곡 |
| 시스템 환경 | CPU affinity 핀 | publisher timer thread / subscriber callback thread / NIC IRQ를 서로 다른 코어에 고정 → OS 스케줄러 간섭 제거 |
| ROS 2 격리 | `ros2 daemon` 비활성화<br>`ros2 daemon stop` | daemon이 participant를 추가 → discovery 트래픽 발생 → 실험 조건 오염 |
| ROS 2 격리 | RMW 구현체 명시<br>`export RMW_IMPLEMENTATION=rmw_fastrtps_cpp` | 미지정 시 환경마다 달라질 수 있음 |
| ROS 2 격리 | Domain 분리<br>`export ROS_DOMAIN_ID=<실험별 고유값>` | 외부 노드 트래픽 유입 차단 |
| 메시지 메모리 | payload 필드(예: `data`, `ranges`)는 노드 초기화 시 1회만 `resize()` | publish 루프 내 `resize()` / `push_back()` 금지 |
| 메시지 메모리 | `PointCloud2`, `Image`, `LaserScan` | 초기화 후 "내용만 덮어쓰기" 패턴 유지 |
| 타이머 정확도 | `WallTimer` 대신 `steady_clock` 기반 타이머 | callback 처리 시간을 빼서 다음 sleep 시간 보정 (특히 200 Hz 이상에서 중요) |
| 워밍업 | discovery 완료 감지 후 워밍업 타이머 시작 | 워밍업 완료 전 데이터는 측정 제외 (eBPF JIT, CPU 캐시, DDS 버퍼 steady-state 목적) |
| 시간 동기화(지연 측정 시) | PTP(IEEE1588, `ptp4l`) | 정확도 < 1 μs, GbE 유선 환경에 최적/권장 |
| 시간 동기화(지연 측정 시) | chrony(NTP) | 정확도 ~100 μs–1 ms, 정밀도 불필요 시 |
| 시간 동기화(지연 측정 시) | CPU 오버헤드만 측정 시 | 동기화 불필요 / latency·observer effect 검증 포함 시 PTP 필수 |

---

## S1 — 원격 제어 (Teleoperation Command)

| 항목 | 값 |
|---|---|
| 토픽 | /cmd_vel |
| 타입 | geometry_msgs/TwistStamped |
| 주기 | 20 Hz (기본) / 50 Hz (상한) |
| CDR 페이로드 | ~72 B (Header 24B + float64 × 6) |
| 총 UDP 패킷 | ~200 B (RTPS 헤더 포함) |
| 추정 대역폭 | ~29 Kbps (20 Hz) / ~72 Kbps (50 Hz) |
| IP 단편화 | 없음 (단일 패킷) |
| E2E 측정 | 가능 (header.stamp 포함) |
| 구간 분류 | 현실 재현 |

> **수정**: 원안의 `geometry_msgs/Twist`에서 `geometry_msgs/TwistStamped`로 변경.
> header.stamp 포함으로 E2E 지연 측정 가능. Nav2 Controller Server 기본값(20 Hz) 및 상한(50 Hz) 기준.
> 논문에서 "실험용으로 TwistStamped 사용" 명시 필요.

---

## S2 — IMU 스트림

| 항목 | 값 |
|---|---|
| 토픽 | /imu |
| 타입 | sensor_msgs/Imu |
| 주기 | 200 Hz |
| CDR 페이로드 | ~320 B (quaternion + 공분산 행렬 3개 포함) |
| 총 UDP 패킷 | ~450 B |
| 추정 대역폭 | ~720 Kbps |
| IP 단편화 | 없음 (단일 패킷) |
| E2E 측정 | 가능 (header.stamp 포함) |
| 구간 분류 | 현실 재현 |

> **수정**: 원안의 "~512 B"는 IMU 공분산 행렬(float64 × 27)을 포함하면
> CDR만 약 320 B이므로 총 패킷 기준 ~450 B로 정정.
> 저대역·고주기 센서의 대표 조합으로 ROS 2 무선 통신 벤치마킹에서
> 널리 사용되는 범위와 동일하다.

---

## S3 — LiDAR 스트림

실제 AMR·자율주행 플랫폼에서 채택되는 LiDAR 센서의 PointCloud2 출력 프로파일을
차용한다. 페이로드 크기는 3단계 센서 계층으로 스윕하며, 각 단계가 자연스럽게
서로 다른 네트워킹 조건을 유발한다.

> 포인트 크기는 Velodyne ROS2 드라이버 기본 출력 기준
> (x, y, z, intensity, ring, time = 22 B/pt).
> 4-byte 정렬 패딩 적용 시 최대 32 B/pt.
> 실험 전 실제 발행된 메시지의 `point_step` 값을
> `ros2 topic echo --once /points`로 확인 후 최종 고정 권장.

### S3-a — 2D LiDAR

| 항목 | 값 |
|---|---|
| 대상 센서 | Hokuyo UST-10LX, SICK TiM5xx, RPLIDAR A3 |
| 토픽 | /scan |
| 타입 | sensor_msgs/LaserScan |
| 주기 | 40 Hz |
| 페이로드 | ~4.3 KB (1,080 pts × 4 B, intensity 미포함) |
| 추정 대역폭 | ~13.8 Mbps |
| IP 단편화 | 발생 (MTU 1500 B 초과) / RTPS DATA_FRAG 없음 |
| E2E 측정 | 가능 (header.stamp 포함) |
| 구간 분류 | 현실 재현 |

실내 AMR, TurtleBot 계열 표준 구성. IP 단편화 재조립 경로 진입의 최소 단계.

### S3-b — 3D LiDAR 16채널

| 항목 | 값 |
|---|---|
| 대상 센서 | Velodyne VLP-16, Robosense RS-LiDAR-16 |
| 토픽 | /points |
| 타입 | sensor_msgs/PointCloud2 |
| 주기 | 20 Hz |
| 페이로드 | ~644 KB (30,000 pts × 22 B/pt) |
| 추정 대역폭 | ~103 Mbps |
| IP 단편화 | 발생 / RTPS DATA_FRAG 발생 (64 KB 초과) |
| E2E 측정 | 가능 (header.stamp 포함) |
| 구간 분류 | 현실 재현 |

Clearpath Husky, Warehouse AMR, Navigation2 데모 대표 구성.
RtpsProcessor DATA_FRAG 재조립 부하 진입.

### S3-c — 3D LiDAR 64채널

| 항목 | 값 |
|---|---|
| 대상 센서 | Velodyne HDL-64E, Hesai Pandar64 |
| 토픽 | /points |
| 타입 | sensor_msgs/PointCloud2 |
| 주기 | 20 Hz |
| 페이로드 | ~2.72 MB (130,000 pts × 22 B/pt) |
| 추정 대역폭 | ~435 Mbps |
| IP 단편화 | 발생 / RTPS DATA_FRAG 발생 (다수 fragment) |
| E2E 측정 | 가능 (header.stamp 포함) |
| 구간 분류 | 현실 재현 |

Autoware 실차 배포 및 nuScenes/KITTI 재생 워크로드 기준 프로파일.
DATA_FRAG fragment 수 증가로 MAX_FRAGMENT_FLOWS 맵 활용률 상승.

---

## S4 — 영상 스트림

무선 텔레오퍼레이션과 인식 파이프라인에서 사용되는 카메라 구성을 차용한다.
네트워크 구간에서의 현실 재현 여부에 따라 두 계층으로 구분한다.

### S4-a — Compressed 원격 감시 영상 (현실 재현)

| 항목 | 값 |
|---|---|
| 토픽 | /image_raw/compressed |
| 타입 | sensor_msgs/CompressedImage |
| 인코딩 | JPEG 품질 80%, 720p (1280×720) |
| 주기 | 30 Hz |
| 페이로드 | ~150 KB |
| 추정 대역폭 | ~36 Mbps |
| RTPS DATA_FRAG | 발생 |
| E2E 측정 | 가능 (header.stamp 포함) |
| 구간 분류 | 현실 재현 |

image_transport를 통해 네트워크 구간에 실제로 흐르는 토픽 형태.
무선 텔레오퍼레이션 표준 영상 대역.

### S4-b — Depth 카메라 스트림 (현실 재현)

| 항목 | 값 |
|---|---|
| 토픽 | /depth/image_raw |
| 타입 | sensor_msgs/Image |
| 인코딩 | 16UC1, 640×480 |
| 주기 | 30 Hz |
| 페이로드 | ~600 KB (640 × 480 × 2 B) |
| 추정 대역폭 | ~147 Mbps |
| RTPS DATA_FRAG | 발생 |
| E2E 측정 | 가능 (header.stamp 포함) |
| 구간 분류 | 현실 재현 |

Intel RealSense, Microsoft Azure Kinect 기반 실내 AMR 로컬라이제이션 표준 구성.

---

## S5 — 현실적 복합 플랫폼 워크로드

단일 토픽 시나리오(S1–S4)와 달리, 실제 로봇 플랫폼에서 동시에 흐르는
토픽 조합을 재현한다. ros2probe의 다중 GID 동시 처리 CPU 오버헤드를
플랫폼 클래스별로 검증한다.

### S5-a — 실내 AMR

| 항목 | 값 |
|---|---|
| 구성 | S1 (/cmd_vel, 20 Hz) + S2 (/imu, 200 Hz) + S3-a (/scan, 40 Hz) + S4-a (/image_raw/compressed, 30 Hz) |
| 활성 GID 수 | 4 |
| 총 추정 대역폭 | ~50 Mbps |
| 대표 플랫폼 | TurtleBot4, Clearpath Jackal (실내 배달·순찰 로봇) |
| 실험 목적 | 저~중대역폭 구간에서 GID 필터 맵·IP 단편화 재조립 동시 처리 부하 측정 |
| 구간 분류 | **현실 재현** |

> **총 추정 대역폭 계산**:
> S1(~0.03 Mbps) + S2(~0.72 Mbps) + S3-a(~13.8 Mbps) + S4-a(~36 Mbps) ≈ ~50 Mbps

### S5-b — 고성능 자율주행 플랫폼 (로보택시)

| 항목 | 값 |
|---|---|
| 구성 | S1 (/cmd_vel, 20 Hz) + S2 (/imu, 200 Hz) + S3-c (/points 64ch, 20 Hz) + S4-a × 2 (/image_raw/compressed 전방·측면, 30 Hz) + S4-b (/depth/image_raw, 30 Hz) |
| 활성 GID 수 | 6 |
| 총 추정 대역폭 | ~655 Mbps |
| 대표 플랫폼 | Autoware 실차, Apollo 배포 플랫폼 |
| 실험 목적 | 고대역폭·다중 DATA_FRAG 동시 처리 시 RtpsProcessor 및 eBPF 파이프라인 부하 측정 |
| 구간 분류 | **현실 재현** (GbE 여유 ~345 Mbps 잔여) |

> **총 추정 대역폭 계산**:
> S1(~0.03 Mbps) + S2(~0.72 Mbps) + S3-c(~435 Mbps)
> + S4-a × 2(~72 Mbps) + S4-b(~147 Mbps) ≈ ~655 Mbps

> **플랫폼 역할**: S3-c publisher는 Jetson 또는 노트북 담당.
> S4-b publisher는 노트북 담당 (RPi는 CPU 한계).

---

## 시나리오 요약표

| 시나리오 | 토픽 | 타입 | 주기 | 페이로드 | 추정 대역폭 | IP 단편화 | DATA_FRAG |
|---|---|---|---|---|---|---|---|---|
| S1 | /cmd_vel | TwistStamped | 20 Hz | ~72 B | ~29 Kbps | ✗ | ✗ | 
| S2 | /imu | Imu | 200 Hz | ~320 B | ~720 Kbps | ✗ | ✗ | 
| S3-a | /scan | LaserScan | 40 Hz | ~4.3 KB | ~13.8 Mbps | ✓ | ✗ | 
| S3-b | /points | PointCloud2 | 20 Hz | ~644 KB | ~103 Mbps | ✓ | ✓ | 
| S3-c | /points | PointCloud2 | 20 Hz | ~2.72 MB | ~435 Mbps | ✓ | ✓ | 
| S4-a | /image_raw/compressed | CompressedImage | 30 Hz | ~150 KB | ~36 Mbps | ✓ | ✓ | 
| S4-b | /depth/image_raw | Image | 30 Hz | ~600 KB | ~147 Mbps | ✓ | ✓ | 
| S5-a | /cmd_vel + /imu + /scan + /image_raw/compressed | — | 20/200/40/30 Hz | — | ~50 Mbps | ✓ | ✓ | 
| S5-b | /cmd_vel + /imu + /points + /image_raw/compressed×2 + /depth/image_raw | — | 20/200/20/30/30 Hz | — | ~655 Mbps | ✓ | ✓ |

---
