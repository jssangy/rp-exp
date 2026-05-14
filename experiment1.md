# Experiment 1: ros2probe 관찰 오버헤드 검증

## 1. 실험 개요

**핵심 주장**

> ros2probe는 DDS subscriber를 생성하지 않고 네트워크 패킷을 passively 관찰하므로, 기존 ROS 2 관찰 도구 대비 네트워크 부하와 원본 subscriber 성능 교란을 최소화한다.
> 동시에 eBPF 기반 관찰 경로를 사용해 `ros2 topic hz`/`ros2 bag record` 대비 CPU·메모리 오버헤드도 낮게 유지한다.

**검증 목표**

- 관찰 도구가 Laptop B의 수신 트래픽(RX)을 얼마나 증가시키는지 측정한다.
- 관찰 도구가 원본 subscriber의 drop rate를 얼마나 악화시키는지 측정한다.
- 관찰 도구별 시스템 CPU 사용률과 메모리 사용량 증가분을 비교한다.
- 네트워크 오버헤드뿐 아니라 resource overhead까지 포함해 ros2probe의 실험적 우위성을 보인다.

**가설**

| 가설 | 내용 |
|---|---|
| H1a | `ros2 topic hz`와 `ros2 bag record`는 DDS subscriber 추가로 Laptop B RX를 증가시킨다 |
| H1b | `rp topic hz`와 `rp bag record`의 baseline 대비 ΔRX는 0에 가깝다 |
| H1c | 대역폭 압박 시 `ros2 bag record`는 원본 subscriber의 drop rate를 증가시킨다 |
| H1d | ros2probe 계열 조건에서는 원본 subscriber의 drop rate 변화가 작다 |
| H1e | `rp topic hz`는 `ros2 topic hz` 대비 CPU·메모리 증가량이 작다 |
| H1f | `rp bag record`는 `ros2 bag record` 대비 CPU·메모리 증가량이 작다 |

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
- **Run 제어**: Laptop B가 event signal로 Laptop A publisher 시작/종료를 제어

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
| S5-b | 복합 자율주행 고대역 | — | — | ~830 Mbps |

S5-a 구성: /cmd_vel(20Hz) + /imu(200Hz) + /scan(40Hz) + /image_raw/compressed(30Hz)

S5-b 구성: /cmd_vel(20Hz) + /imu(200Hz) + /points/front 64ch(20Hz) + /points/rear 16ch(20Hz) + /camera/front/compressed(30Hz) + /camera/left/compressed(30Hz) + /camera/right/compressed(30Hz) + /camera/rear/compressed(30Hz) + /depth/image_raw(30Hz)

S5 publisher/subscriber는 단일 복합 노드가 아니라 launch 파일로 S1~S4 개별 노드를 조합해 실행한다. 이는 실제 로봇 시스템처럼 여러 프로세스·여러 DDS participant가 동시에 존재하는 상황을 재현하기 위함이다.

### 3.2 관찰 도구 조건

| 조건 | S1~S4 | S5-a | S5-b |
|---|---|---|---|
| A. baseline | — | — | — |
| B. topic hz | `ros2 topic hz /<topic>` | `ros2 topic hz /image_raw/compressed` | `ros2 topic hz /points/front` |
| C. rosbag2 | `ros2 bag record /<topic>` | `ros2 bag record --all` | `ros2 bag record --all` |
| D. rp topic hz | `rp topic hz /<topic>` | `rp topic hz /image_raw/compressed` | `rp topic hz /points/front` |
| E. rp bag record | `rp bag record /<topic>` | `rp bag record --all` | `rp bag record --all` |

**반복 횟수**: 조건당 10회

---

## 4. 측정 지표

| 지표 | 측정 방법 | 측정 위치 |
|---|---|---|
| ΔRX (bytes/s) | `/proc/net/dev` 1초 간격 샘플링, 60s 측정 창 평균 | Laptop B NIC |
| 메시지 드롭률 | subscriber 60s 수신 카운트 vs expected(Hz×60) | Laptop B |
| 시스템 CPU 사용률 (%) | `/proc/stat` idle 델타 기반 1초 간격 샘플링, 모든 조건에서 측정 | Laptop B 전체 시스템 |
| 시스템 메모리 사용량 (KB) | `/proc/meminfo` MemTotal−MemAvailable 1초 간격 샘플링 | Laptop B 전체 시스템 |

CPU·메모리는 특정 observer 프로세스의 RSS만 보는 것이 아니라 Laptop B 전체 시스템 사용량을 측정한다. 따라서 분석 시 baseline 대비 증가량(ΔCPU, ΔMem)을 사용한다.

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

## 6. 실험 절차 (1 run 기준)

```
[사전]
1. 환경 변수 설정 (CPU governor, RMW, DOMAIN_ID)

[Laptop B]
2. Observer 도구 실행 (백그라운드)        ← baseline이면 skip
   - ros2 topic hz, ros2 bag record, rp topic hz, rp bag record
   - rp run은 DDS participant 생성 전(discovery 단계)부터 프로빙해야 하므로
     publisher보다 먼저 실행

[Laptop A]
3. Publisher 실행 (event START 신호 수신 후)

[Laptop B]
4. Subscriber 백그라운드 실행
   → 내부 10s warm-up 자동 시작 (DDS discovery + observer 연결 대기)
5. 10s warm-up 대기 후 /proc/net/dev, CPU, memory 샘플링 시작 (1초 간격, 백그라운드)
   → t=10s: 측정 창 시작 (자동)
   → t=70s: FINAL 출력 후 subscriber 자동 종료

[완료]
6. Subscriber 프로세스 종료 확인 → run 완료
7. 백그라운드 프로세스 종료 (sampler, observer 도구, publisher)
   - Event control: B → A "STOP" 신호 → A publisher 종료
   - B는 run에서 시작한 process group만 종료해 다른 ROS 프로세스 오염 방지
8. 결과 저장 (sub.log, netdev.log, obs.log, cpu_mem.log)
9. 10s 대기 후 다음 run
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
│   ├── topic_hz/   run01~10/ (sub.log, netdev.log, obs.log, cpu_mem.log)
│   ├── rosbag2/    run01~10/ (sub.log, netdev.log, obs.log, cpu_mem.log)
│   ├── rp_hz/      run01~10/ (sub.log, netdev.log, obs.log, cpu_mem.log)
│   └── rp_bag/     run01~10/ (sub.log, netdev.log, obs.log, cpu_mem.log)
├── S2/ ...
└── S5b/

bags/exp1/
├── S1/
│   ├── rosbag2/    run01~10/ rosbag2/ (mcap)
│   └── rp_bag/     run01~10/ rp.mcap
└── ...
```

### 7.1 로그 파일 설명

| 파일 | 내용 |
|---|---|
| sub.log | subscriber stdout: 5초 단위 수신 rate + `FINAL` 드롭률 |
| netdev.log | 1초 간격 NIC rx_bytes (`timestamp_ms rx_bytes`) |
| obs.log | observer 도구 stdout/stderr |
| cpu_mem.log | 1초 간격 전체 시스템 CPU%·메모리 사용량 (`timestamp_ms cpu% used_kb`) |

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

### 8.3 CPU / 메모리

```
cpu_mem.log 컬럼: timestamp_ms  cpu%  used_kb
(모든 조건에서 시스템 전체 측정 — baseline 대비 증가량 비교용)

# Python으로 조건별 평균·최대 계산
python3 -c "
import sys
lines = [l.split() for l in open('cpu_mem.log')]
cpus = [float(l[1]) for l in lines]
mems = [int(l[2])   for l in lines]
print(f'cpu avg={sum(cpus)/len(cpus):.1f}% max={max(cpus):.1f}%')
print(f'mem avg={sum(mems)/len(mems):.0f}KB max={max(mems):.0f}KB')
"

# baseline 대비 증가량 계산 예시
# Δcpu = cpu%(condition) - cpu%(baseline)
# Δmem = used_kb(condition) - used_kb(baseline)
```

CPU·메모리 분석은 절대값보다 baseline 대비 증가량을 우선 사용한다. Laptop B의 background load가 완전히 0이 아니므로 조건별 평균값만 직접 비교하면 시스템 상태 차이가 섞일 수 있다.

권장 보고 방식:

| 비교 | 보고 지표 |
|---|---|
| `topic_hz` vs `rp_hz` | ΔRX, Δdrop, ΔCPU avg/max, ΔMem avg/max |
| `rosbag2` vs `rp_bag` | ΔRX, Δdrop, ΔCPU avg/max, ΔMem avg/max |
| 각 조건 vs baseline | observer가 원본 workload에 추가한 부하 |
