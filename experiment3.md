# Experiment 3: Stress Test

## 1. 실험 개요

**핵심 주장**

> `ros2 topic hz`는 DDS DataReader를 추가해 원본 subscriber와 같은 data stream을 한 번 더 수신하고, ROS 2 subscription path를 거치므로 고주기 workload에서 observer process CPU 사용량이 커질 수 있다.
> 반면 `rp topic hz`는 DDS subscriber를 생성하지 않고 passive packet capture 기반으로 동작하므로, RX traffic을 baseline 근처로 유지하면서 더 낮은 observer CPU overhead를 보일 수 있다.

**검증 목표**

- 고주기 message stream에서 `rp_hz`와 `topic_hz` 조건의 observer process CPU 사용량을 비교한다.
- PC, Raspberry Pi, Jetson 환경에서 platform별 resource overhead와 failure point를 비교한다.
- subscriber drop rate는 resource 측정 중 workload가 정상 유지되었는지 확인하는 유효성 지표로만 사용한다.

**가설**

| 가설 | 내용 |
|---|---|
| H3a | `ros2 topic hz`는 baseline 대비 RX traffic을 증가시킨다 |
| H3b | `rp topic hz`의 baseline 대비 RX traffic 증가는 0에 가깝다 |
| H3c | 고주기 조건에서 `rp topic hz`는 `ros2 topic hz`보다 observer process CPU 사용량이 낮다 |

---

## 2. 네트워크 및 플랫폼 구성

```
Publisher Host ──── GbE ──── Receiver Platform
    │                          │
Stress publisher           Original subscriber
                            + observer condition
                            + resource sampler
```

- **Publisher Host**: 고정 PC 1대
- **Receiver Platform**: PC, Raspberry Pi, Jetson
- **DDS 벤더**: FastDDS (rmw_fastrtps_cpp)
- **Discovery**: multicast (FastDDS 기본값)
- **Data 전송**: unicast (FastDDS 기본값)
- **ROS_DOMAIN_ID**: Experiment 1/2와 충돌하지 않는 고유 domain 사용
- **측정 위치**: Receiver Platform

플랫폼별로 가능한 한 다음 조건을 고정한다.

| 항목 | 설정 |
|---|---|
| CPU governor | performance |
| Jetson power mode | 고정된 최대 성능 mode |
| Network | 가능하면 유선 GbE |
| Storage | platform별 저장장치 종류 기록 |
| Thermal state | throttling 여부 기록 |

---

## 3. 실험 조건

### 3.1 Stress workload

payload 크기는 고정하고 publish rate만 증가시킨다. 목적은 네트워크 포화 자체가 아니라 message rate 증가에 따른 subscriber와 관찰 조건의 처리 비용을 비교하는 것이다.

| 시나리오 | 토픽 | payload | publish rate | payload bandwidth |
|---|---|---:|---:|---:|
| ST100 | `/stress` | 64 KiB | 100 Hz | 약 52.4 Mbps |
| ST500 | `/stress` | 64 KiB | 500 Hz | 약 262.1 Mbps |
| ST1000 | `/stress` | 64 KiB | 1000 Hz | 약 524.3 Mbps |

payload bandwidth 계산:

```text
64 KiB = 65,536 bytes
bandwidth = 65,536 bytes x rate x 8
```

실제 NIC RX는 DDS/UDP/IP/Ethernet overhead 때문에 payload bandwidth보다 높을 수 있다.

### 3.2 관찰 조건

모든 조건에서 Receiver Platform의 original subscriber는 항상 실행한다.

| 조건 | Receiver Platform 동작 | 의도 |
|---|---|---|
| A. baseline | original subscriber만 실행 | 관찰 조건 없는 기준 RX/drop |
| B. rp_hz | original subscriber + `rp topic hz /stress` | passive observer 조건의 overhead 측정 |
| C. topic_hz | original subscriber + `ros2 topic hz /stress` | DDS subscriber 기반 observer 조건의 overhead 측정 |

**반복 횟수**: platform x scenario x condition당 10회

전체 run 수:

```text
3 platforms x 3 scenarios x 3 conditions x 10 repetitions = 270 runs
```

초기 pilot은 platform x scenario x condition당 3회로 줄여 실행할 수 있다.

---

## 4. 측정 지표

| 지표 | 측정 방법 | 측정 위치 |
|---|---|---|
| RX bytes/s | `/proc/net/dev` 1초 간격 샘플링 | Receiver NIC |
| 원본 subscriber drop rate | subscriber 수신 count vs expected(rate x 60s) | Receiver |
| observer process CPU % | observer PID 기준 process CPU 샘플링 | Receiver |
| platform health | temperature/throttling 상태 | Receiver |

주요 비교 지표:

```text
ΔRX = RX(condition) - RX(baseline)
observer CPU = observer_cpu(condition)
```

이 실험은 bag 파일을 생성하지 않는다. 저장장치 I/O를 배제하고 observer 경로가 RX와 observer CPU에 주는 영향을 비교한다.

---

## 5. 실험 절차

### 5.1 사전 환경 설정

Publisher Host, Receiver Platform 공통:

```bash
source /opt/ros/humble/setup.bash
source install/setup.bash
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_DOMAIN_ID=<exp3_domain>
ros2 daemon stop
```

Receiver Platform:

```bash
sudo cpupower frequency-set -g performance
```

Jetson은 별도로 power mode와 clock 상태를 기록한다.

### 5.2 1 run 절차

```
[사전]
1. Publisher/Receiver에서 ROS_DOMAIN_ID, RMW 설정
2. Receiver에서 ros2 daemon stop
3. 이전 run의 publisher, subscriber, observer, sampler process 종료 확인
4. 결과 디렉토리 생성

[Receiver]
5. 조건별 observer 준비
   - baseline: skip
   - rp_hz: sudo rp run 실행 후 rp topic hz /stress 준비
   - topic_hz: ros2 topic hz /stress 준비

[Publisher]
6. scenario별 stress publisher 실행
   - ST100/ST500/ST1000 중 하나

[Receiver]
7. original subscriber 실행
8. 10s warm-up
9. 60s measurement 시작
   - netdev sampler
   - observer process CPU sampler
   - subscriber count
10. measurement 종료
11. subscriber 종료
12. observer 종료
13. publisher 종료
14. observer exit status 저장
15. ros2 daemon stop
16. 10s cooldown
```

Experiment 1과 동일하게 10초 warm-up을 둔다. 이 구간은 DDS discovery, endpoint matching, observer startup 영향을 측정 창에서 제외하기 위한 것이다.

---

## 6. 결과 디렉토리 구조

```
results/exp3/
├── pc/
│   ├── ST100/
│   │   ├── baseline/
│   │   │   └── run01~10/
│   │   │       ├── sub.log
│   │   │       ├── netdev.log
│   │   │       ├── observer_cpu.log
│   │   │       └── platform.log
│   │   ├── rp_hz/
│   │   │   └── run01~10/
│   │   │       ├── obs.log
│   │   │       └── ...
│   │   └── topic_hz/
│   │       └── run01~10/
│   ├── ST500/
│   └── ST1000/
├── rpi/
└── jetson/
```

| 파일 | 내용 |
|---|---|
| sub.log | original subscriber 수신 count, FINAL drop rate |
| netdev.log | 1초 간격 NIC rx_bytes |
| observer_cpu.log | 1초 간격 observer process CPU% |
| obs.log | observer stdout/stderr |
| platform.log | CPU governor, temperature, throttling, storage 정보 |

---

## 7. 분석 방법

### 7.1 RX overhead

```text
RX Mbps = (rx_bytes[end] - rx_bytes[start]) x 8 / duration / 1e6
ΔRX(condition) = RX(condition) - RX(baseline)
```

기대 결과:

| 조건 | 예상 RX |
|---|---|
| baseline | 기준값 |
| rp_hz | baseline 근처 |
| topic_hz | baseline보다 증가 |

### 7.2 Observer CPU Overhead

observer process CPU 사용량을 조건별로 비교한다. baseline은 observer process가 없으므로 observer CPU 비교에서는 제외하고, RX/drop 기준값으로만 사용한다.

| 비교 | 보고 지표 |
|---|---|
| rp_hz | observer process CPU 평균/최대 |
| topic_hz | observer process CPU 평균/최대 |
| topic_hz vs rp_hz | observer process CPU 차이 |

platform별 core 수가 다르므로 process CPU는 raw value와 normalized value를 함께 보고한다.

```text
normalized CPU = observer process CPU / logical_core_count
```

### 7.3 Drop Rate Validity Check

drop rate는 primary claim이 아니라 resource 측정의 validity guardrail로만 사용한다.

```text
drop_rate = (expected - received) / expected x 100
expected = publish_rate x 60s
```

observer CPU가 낮더라도 subscriber count가 낮으면 해당 run의 resource 측정은 정상 workload 조건으로 해석하지 않는다.

### 7.4 Platform 비교

PC, Raspberry Pi, Jetson에 대해 다음을 비교한다.

```text
observer CPU at ST1000
thermal throttling 발생 여부
observer 실패 여부
```

---

## 8. 유효성 기준

| 항목 | valid 기준 |
|---|---|
| baseline | original subscriber FINAL line 존재, observer process 없음 |
| rp_hz | `rp run` socket ready, `rp topic hz` 정상 시작 및 종료 |
| topic_hz | `ros2 topic hz` 정상 시작 및 종료, run 전후 `ros2 daemon stop` 수행 |
| sampler | netdev/observer CPU sampler가 60초 측정 창을 포함 |
| subscriber | expected count와 received count 기록 |
| platform | CPU governor/power mode/thermal 상태 기록 |

invalid 처리 예:

```text
subscriber FINAL line 없음
observer startup 실패
sampler 누락
measurement window 중 process crash
thermal throttling 발생 후 platform 비교에 포함
```
