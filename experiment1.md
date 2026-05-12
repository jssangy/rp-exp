# Experiment 1: ros2probe 관찰 행위가 네트워크에 미치는 영향

## 1. 실험 개요

**핵심 주장**

> ros2probe는 DDS subscriber를 생성하지 않으므로 관찰 행위 자체가 네트워크에 영향을 주지 않는다.

**가설**

| 가설 | 내용 |
|---|---|
| H1a | rosbag2/topic echo/topic hz는 DDS subscriber 추가로 Laptop B RX를 증가시킨다 |
| H1b | ros2probe의 ΔRX ≈ 0 |
| H1c | 대역폭 압박 시 rosbag2 계열은 원본 subscriber의 드롭률을 유의미하게 증가시킨다 |
| H1d | ros2probe 활성 시 드롭률 변화 없음 |
| H1e | rosbag2 계열은 E2E latency를 유의미하게 증가시킨다 |
| H1f | ros2probe 활성 시 E2E latency 변화 없음 |

---

## 2. 네트워크 구성

```
Laptop A ──── GbE ──── Laptop B
    │                      │
Publisher          Original Subscriber
                   + Observer 도구
```

- **DDS 벤더**: FastDDS (rmw_fastrtps_cpp)
- **Discovery**: multicast (FastDDS 기본값)
- **Data 전송**: unicast (FastDDS 기본값)
- 실험 전 tshark로 data 패킷 unicast 1회 검증

---

## 3. 실험 조건

### 3.1 워크로드 시나리오

| 시나리오 | 토픽 | 주기 | 페이로드 | 대역폭 |
|---|---|---|---|---|
| S1 | /cmd_vel (TwistStamped) | 20 Hz | ~72 B | ~29 Kbps |
| S2 | /imu | 200 Hz | ~320 B | ~720 Kbps |
| S3-a | /scan | 40 Hz | ~4.3 KB | ~13.8 Mbps |
| S3-b | /points (VLP-16, 16ch) | 20 Hz | ~644 KB | ~103 Mbps |
| S3-c | /points (64ch) | 20 Hz | ~2.72 MB | ~435 Mbps |
| S4-a | /image_raw/compressed | 30 Hz | ~150 KB | ~36 Mbps |
| S4-b | /depth/image_raw | 30 Hz | ~600 KB | ~147 Mbps |
| S5-a | 복합 실내 AMR | — | — | ~50 Mbps |
| S5-b | 복합 자율주행 | — | — | ~655 Mbps |

S5-a 구성: /cmd_vel(20Hz) + /imu(200Hz) + /scan(40Hz) + /image_raw/compressed(30Hz)

S5-b 구성: /cmd_vel(20Hz) + /imu(200Hz) + /points 64ch(20Hz) + /camera/front/compressed(30Hz) + /camera/side/compressed(30Hz) + /depth/image_raw(30Hz)

### 3.2 관찰 도구 조건

| 조건 | S1~S4 | S5-a | S5-b |
|---|---|---|---|
| A. baseline | — | — | — |
| B. topic hz | `ros2 topic hz /<topic>` | `ros2 topic hz /image_raw/compressed` | `ros2 topic hz /points` |
| C. rosbag2 | `ros2 bag record /<topic>` | `ros2 bag record --all` | `ros2 bag record --all` |
| D. rp topic hz | `rp topic hz /<topic>` | `rp topic hz /image_raw/compressed` | `rp topic hz /points` |
| E. rp bag record | `rp bag record /<topic>` | `rp bag record --all` | `rp bag record --all` |

**반복 횟수**: 조건당 10회

---

## 4. 측정 지표

| 지표 | 측정 방법 | 측정 위치 |
|---|---|---|
| ΔRX (bytes/s) | `/proc/net/dev` 1초 간격 샘플링, 60s 측정 창 평균 | Laptop B NIC |
| 메시지 드롭률 | subscriber 60s 수신 카운트 vs expected(Hz×60) | Laptop B |
| E2E latency p50/p95/p99 | header.stamp 기반, 측정 창 동안 메시지마다 sub.log에 기록 후 후처리, PTP 동기화 전제 | Laptop B subscriber 내장 |

---

## 5. 사전 환경 설정

### 5.1 1회 설정 (Laptop A, B 공통)

```bash
sudo cpupower frequency-set -g performance
ros2 daemon stop
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_DOMAIN_ID=77
```

### 5.2 FastDDS unicast 확인 (1회만)

```bash
# Laptop B
sudo tshark -i eth0 -f "udp" -T fields -e ip.dst -c 30
# 개별 IP 주소(unicast)가 출력되면 확인 완료
```

### 5.3 PTP 동기화

```bash
# Laptop A (Master)
sudo ptp4l -i eth0 -m --slave_only 0

# Laptop B (Slave)
sudo ptp4l -i eth0 -s -m
sudo phc2sys -s eth0 -w -m

# 동기화 품질 확인 (offset < ±1μs 목표)
sudo ptp4l -i eth0 2>&1 | grep "master offset"
```

---

## 6. 실험 절차 (1 run 기준)

```
[사전]
1. 환경 변수 설정 (CPU governor, RMW, DOMAIN_ID)
2. PTP 동기화 확인 (offset < ±1μs)

[Laptop B]
3. Observer 도구 실행 (백그라운드)        ← baseline이면 skip
   - ros2 topic hz, ros2 bag record, rp topic hz, rp bag record
   - rp run은 DDS participant 생성 전(discovery 단계)부터 프로빙해야 하므로
     publisher보다 먼저 실행

[Laptop A]
4. Publisher 실행 (WiFi 동기화 신호 수신 후)

[Laptop B]
5. Subscriber 백그라운드 실행
   → 내부 10s warm-up 자동 시작 (DDS discovery + observer 연결 대기)
6. 10s warm-up 대기 후 /proc/net/dev 샘플링 시작 (1초 간격, 백그라운드)
   → t=10s: 측정 창 시작 (자동)
   → t=70s: FINAL 출력 후 subscriber 자동 종료

[완료]
7. Subscriber 프로세스 종료 확인 → run 완료
8. 백그라운드 프로세스 종료 (netdev 샘플링, observer 도구, publisher)
   - WiFi 동기화: B → A "STOP" 신호 → A publisher 종료
9. 결과 저장 (sub.log, netdev.log, obs.log)
10. 10s 대기 후 다음 run
```

### 6.1 실행 명령

```bash
# Laptop A
./scripts/run_exp1_pub.sh --sync <Laptop-B-wlan-IP>

# Laptop B
./scripts/run_exp1_sub.sh --sync <Laptop-A-wlan-IP>
```

`scripts/run_b.sh` — 단일 run 자동화 (run_exp1_sub.sh가 호출):

```bash
# Step 3: observer 실행 (rp run은 pub보다 먼저 실행)
# Step 4: WiFi로 A에 "START <scenario>" → A pub 시작 → "READY" 수신
# Step 5: subscriber 백그라운드 실행
# Step 6: 10s 후 netdev 샘플링 시작
#         subscriber 60s 측정 후 자동 종료
# Step 7: subscriber 종료 확인
# Step 8: A에 "STOP" → A pub 종료, observer/netdev 정리
# Step 9: 10s 대기
```

---

## 7. 결과 디렉토리 구조

```
results/exp1/
├── S1/
│   ├── baseline/   run01~10/ (sub.log, netdev.log)
│   ├── topic_hz/   run01~10/
│   ├── rosbag2/    run01~10/ (sub.log, netdev.log, obs.log, bag/)
│   ├── rp_hz/      run01~10/
│   └── rp_bag/     run01~10/
├── S2/
├── S3a/
├── S3b/
├── S3c/
├── S4a/
├── S4b/
├── S5a/
└── S5b/
```

### 7.1 로그 파일 설명

| 파일 | 내용 |
|---|---|
| sub.log | subscriber stdout: 5s 창 latency avg/max, FINAL 드롭률 |
| netdev.log | 1초 간격 NIC rx/tx bytes (timestamp rx_bytes tx_bytes) |
| obs.log | observer 도구 stdout |

---

## 8. 분석 방법 (예정)

### 8.1 ΔRX

```
netdev.log에서 측정 창(t_start ~ t_start+60s) 구간 추출
ΔRX = (rx_bytes[t_end] - rx_bytes[t_start]) / 60  [bytes/s]
baseline 대비 증가량 = ΔRX(condition) - ΔRX(baseline)
```

### 8.2 드롭률

```
sub.log에서 FINAL 라인 파싱:
  "FINAL [60s]: recv X / expected Y → drop Z%"
drop_rate = (expected - received) / expected × 100
```

### 8.3 E2E latency

sub.log에는 측정 창 동안 메시지마다 `LAT <ms>` (S5는 `LAT <topic> <ms>`) 한 줄씩 기록된다.

```bash
# latency 값 추출
grep "^LAT" sub.log | awk '{print $NF}' > latency.txt

# Python으로 percentile 계산
python3 -c "
import statistics, sys
vals = [float(l) for l in open('latency.txt')]
vals.sort()
n = len(vals)
print(f'n={n}')
print(f'p50 = {vals[int(n*0.50)]:.3f} ms')
print(f'p95 = {vals[int(n*0.95)]:.3f} ms')
print(f'p99 = {vals[int(n*0.99)]:.3f} ms')
print(f'max = {vals[-1]:.3f} ms')
"
```
