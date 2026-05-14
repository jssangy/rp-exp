# Experiment 2: DDS Discovery 관찰 오버헤드 검증

## 1. 실험 개요

**핵심 주장**

> `ros2 daemon`은 ROS graph cache를 유지하기 위해 DDS Participant로 등장하므로 SPDP/SEDP discovery traffic과 participant count를 증가시킨다.
> 반면 ros2probe의 평시 관찰 경로(`rp run`)는 AF_PACKET/eBPF 기반 passive capture만 수행하고 DDS Participant를 생성하지 않으므로 SPDP/SEDP traffic에 기여하지 않는다.

**검증 목표**

- 관찰 도구 실행 전후 Laptop B에서 추가 DDS Participant가 생성되는지 확인한다.
- 관찰 도구 실행 전후 SPDP/SEDP packet count와 byte count가 증가하는지 측정한다.
- `ros2 daemon`과 ros2probe의 discovery overhead 차이를 정량화한다.

**가설**

| 가설 | 내용 |
|---|---|
| H2a | `ros2 daemon`은 DDS Participant를 생성하므로 baseline 대비 participant count를 증가시킨다 |
| H2b | `ros2 daemon`은 baseline 대비 SPDP/SEDP packet 및 byte count를 증가시킨다 |
| H2c | `rp run`은 DDS Participant를 생성하지 않으므로 baseline 대비 participant count 변화가 없다 |
| H2d | `rp run`의 baseline 대비 SPDP/SEDP traffic 증가는 0에 가깝다 |

---

## 2. 네트워크 구성

```
Laptop A ──── GbE ──── Laptop B
    │                      │
Fixed ROS 2 node      Observer condition
                      + packet capture
```

- **DDS 벤더**: FastDDS (rmw_fastrtps_cpp)
- **Discovery**: multicast (FastDDS 기본값)
- **측정 위치**: Laptop B NIC
- **패킷 캡처**: `tshark` 또는 `tcpdump`
- **ROS_DOMAIN_ID**: Experiment 1과 분리된 고유 domain 사용 권장

---

## 3. 실험 조건

### 3.1 고정 ROS 2 workload

Discovery traffic만 보기 위해 workload는 단순하게 유지한다.

| 역할 | 실행 위치 | 노드 | 토픽 |
|---|---|---|---|
| Publisher | Laptop A | `s1_pub` | `/cmd_vel` |
| Subscriber | Laptop B | 없음 | — |

기본 실행:

```bash
# Laptop A
ros2 run test s1_pub
```

Laptop B에는 조건별 관찰 도구와 packet capture만 실행한다. Laptop B에 subscriber를 두지 않는 이유는 `ros2 daemon` 또는 ros2probe 외의 DDS Participant 증가를 피하기 위함이다.

### 3.2 관찰 도구 조건

| 조건 | Laptop B 동작 | 의도 |
|---|---|---|
| A. baseline | 아무 ROS graph 관찰 도구도 실행하지 않음 | Laptop A publisher만 존재하는 기준 discovery traffic |
| B. ros2probe | `sudo rp run` 실행 | passive capture runtime이 participant를 만들지 않는지 확인 |
| C. ros2 daemon | `ros2 daemon start` 실행 후 유지 | daemon participant가 discovery traffic을 증가시키는지 확인 |

`ros2 topic list --no-daemon`은 이번 실험 조건에서 제외한다. 이 명령은 짧게 실행되고 종료되는 active graph query이며, 상주 관찰자 역할의 `ros2 daemon` 및 `rp run`과 성격이 다르기 때문이다.

**반복 횟수**: 조건당 10회

---

## 4. 측정 지표

| 지표 | 측정 방법 | 측정 위치 |
|---|---|---|
| SPDP packet count | pcap에서 RTPS SPDP packet 수 파싱 | Laptop B NIC |
| SEDP packet count | pcap에서 RTPS SEDP packet 수 파싱 | Laptop B NIC |
| SPDP/SEDP byte count | 해당 packet frame length 합산 | Laptop B NIC |
| Participant count | SPDP/SEDP에서 unique participant GUID prefix 추출 | Laptop B NIC |
| Laptop B participant count | Laptop B IP를 source로 하는 participant GUID count | Laptop B NIC |

주요 비교 지표:

```text
ΔSPDP packets = packets(condition) - packets(baseline)
ΔSEDP packets = packets(condition) - packets(baseline)
Δdiscovery bytes = bytes(condition) - bytes(baseline)
Δparticipant count = participants(condition) - participants(baseline)
```

---

## 5. 실험 절차

### 5.1 사전 환경 설정

Laptop A, B 공통:

```bash
source /opt/ros/humble/setup.bash
source install/setup.bash
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_DOMAIN_ID=78
ros2 daemon stop
```

Laptop B:

```bash
sudo cpupower frequency-set -g performance
```

### 5.2 1 run 절차

```
[사전]
1. Laptop A/B에서 ROS_DOMAIN_ID=78, RMW=FastDDS 설정
2. Laptop B에서 ros2 daemon stop
3. 이전 조건의 rp run, ros2 daemon, capture process 종료 확인

[Laptop A]
4. fixed publisher 실행: ros2 run test s1_pub

[Laptop B]
5. 조건별 observer 실행
   - baseline: skip
   - ros2probe: sudo rp run
   - ros2 daemon: ros2 daemon start
6. 10s warm-up
7. 60s packet capture
8. observer 종료
9. ros2 daemon stop
10. 10s cooldown
```

### 5.3 캡처 명령 예시

```bash
sudo tshark -i <NIC> \
  -f "udp portrange 7400-7600" \
  -a duration:60 \
  -w results/exp2/<condition>/run01/discovery.pcapng
```

FastDDS 기본 RTPS discovery는 보통 UDP 7400번대 포트를 사용한다. 최종 분석은 capture filter가 아니라 pcap 내 RTPS dissector 결과를 기준으로 한다.

---

## 6. 결과 디렉토리 구조

```
results/exp2/
├── baseline/
│   └── run01~10/
│       ├── discovery.pcapng
│       ├── summary.csv
│       └── obs.log
├── rp_run/
│   └── run01~10/
│       ├── discovery.pcapng
│       ├── summary.csv
│       └── obs.log
└── ros2_daemon/
    └── run01~10/
        ├── discovery.pcapng
        ├── summary.csv
        └── obs.log
```

| 파일 | 내용 |
|---|---|
| discovery.pcapng | 60초 RTPS/DDS packet capture |
| summary.csv | run별 SPDP/SEDP packet, byte, participant count 요약 |
| obs.log | 조건별 observer stdout/stderr |

---

## 7. 분석 방법

### 7.1 SPDP/SEDP packet count

`tshark`로 RTPS 필드를 확인한 뒤 SPDP/SEDP packet을 분류한다.

```bash
tshark -G fields | grep -i rtps | grep -Ei "spdp|sedp|guid|entity"
```

후보 파싱:

```bash
tshark -r discovery.pcapng -Y "rtps" -T fields \
  -e frame.time_epoch \
  -e frame.len \
  -e ip.src \
  -e ip.dst \
  -e udp.srcport \
  -e udp.dstport
```

SPDP/SEDP 분류는 Wireshark/tshark RTPS field availability에 따라 조정한다. 필요하면 RTPS well-known entity id를 기준으로 직접 parser를 작성한다.

### 7.2 Participant count

SPDP participant announcement에서 GUID prefix를 추출해 unique count를 계산한다.

보고 지표:

| 비교 | 보고 지표 |
|---|---|
| `ros2_daemon` vs baseline | Δparticipant count, ΔSPDP/SEDP packets, Δdiscovery bytes |
| `rp_run` vs baseline | Δparticipant count, ΔSPDP/SEDP packets, Δdiscovery bytes |
| `ros2_daemon` vs `rp_run` | discovery overhead 차이 |

### 7.3 기대 결과

| 조건 | 예상 participant 증가 | 예상 discovery traffic 증가 |
|---|---|---|
| baseline | 없음 | 기준값 |
| rp_run | 없음 | 기준값 근처 |
| ros2_daemon | 있음 | 증가 |

---

## 8. 유효성 기준

| 조건 | valid 기준 |
|---|---|
| baseline | Laptop B에서 ROS graph observer process 없음, `ros2 daemon stop` 상태 |
| rp_run | `rp run` socket ready, ROS 2 node/participant 생성 없음 |
| ros2_daemon | `ros2 daemon start` 성공, run 종료 후 `ros2 daemon stop` 수행 |
| pcap | 60초 capture 존재, RTPS packet 파싱 가능 |

`rp discover`는 active discovery trigger이므로 이 실험의 ros2probe 조건에 포함하지 않는다.
