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
Scaled publisher      Scaled subscriber
processes             processes
                       + observer condition
                       + packet capture
```

- **DDS 벤더**: FastDDS (rmw_fastrtps_cpp)
- **Discovery**: multicast (FastDDS 기본값)
- **측정 위치**: Laptop B NIC
- **패킷 캡처**: `tshark` 또는 `tcpdump`
- **ROS_DOMAIN_ID**: Experiment 1과 분리된 고유 domain 사용 권장

---

## 3. 실험 조건

### 3.1 ROS 2 workload scale

Discovery traffic만 보기 위해 workload는 단순한 pub-sub process pair 집합으로 유지한다. 독립 변수는 토픽 의미나 payload가 아니라 **독립 ROS 2 process 수와 endpoint 수**이다.

Discovery Storm 논문의 계층 모델을 따라 다음과 같이 정의한다.

| 계층 | 이 실험의 정의 | DDS 대응 |
|---|---|---|
| Host H | Laptop A/B, 총 2 hosts | NIC/IP를 가진 network host |
| Process P | 독립 실행된 publisher/subscriber process | ROS 2 Context / DDS DomainParticipant |
| Endpoint E | 각 process 안의 publisher 또는 subscriber 1개 | DataWriter / DataReader |

각 publisher/subscriber process는 일반적으로 하나의 ROS 2 Context를 만들고, 따라서 하나의 DDS Participant를 만든다. 하나의 process 안에 여러 ROS 2 node를 composition하면 participant 수가 기대만큼 증가하지 않을 수 있으므로 이 실험에서는 multi-node composition을 사용하지 않는다.

| scale | Laptop A | Laptop B | total participants | total endpoints | 의도 |
|---|---:|---:|---:|---:|---|
| G1 | 1 pub process | 1 sub process | 2 | 2 | 최소 graph sanity check |
| G5 | 5 pub processes | 5 sub processes | 10 | 10 | small graph |
| G10 | 10 pub processes | 10 sub processes | 20 | 20 | medium graph |
| G20 | 20 pub processes | 20 sub processes | 40 | 40 | large graph |
| G50 | 50 pub processes | 50 sub processes | 100 | 100 | stress graph |

토픽 이름은 pub-sub pair를 구분하기 위해 index만 붙인다. 토픽명 자체는 독립 변수가 아니다.

```text
G1:  /exp2/topic_001
G5:  /exp2/topic_001 ... /exp2/topic_005
G10: /exp2/topic_001 ... /exp2/topic_010
G20: /exp2/topic_001 ... /exp2/topic_020
G50: /exp2/topic_001 ... /exp2/topic_050
```

Laptop B에는 scale별 subscriber process, 조건별 관찰 도구, packet capture를 실행한다. subscriber process는 baseline/rp_run/ros2_daemon 조건 모두에 동일하게 포함되므로, observer overhead는 각 scale 내부에서 condition과 baseline의 차이로 계산한다.

workload startup 방식은 모든 observer 조건에서 동일해야 한다. 기본값은 같은 scale의 publisher/subscriber process들을 가능한 한 동시 또는 연속적으로 실행하는 synchronized startup이다. 만약 G50에서 packet drop 또는 process startup 실패가 반복되면, staggered startup은 discovery storm 완화 조건으로 분리하거나, 모든 조건에 동일한 간격으로 적용하고 간격을 결과 metadata에 기록한다.

이 실험은 Discovery Storm 논문의 H/P/E scaling 관점을 채택하지만, 해당 논문의 IEEE 802.11 airtime saturation 모델을 직접 검증하지 않는다. 본 실험의 측정 대상은 제어된 GbE 링크에서 observer가 추가로 유발하는 DDS discovery traffic이다.

### 3.2 관찰 도구 조건

| 조건 | Laptop B 동작 | 의도 |
|---|---|---|
| A. baseline | 아무 ROS graph 관찰 도구도 실행하지 않음 | scale별 pub-sub process만 존재하는 기준 discovery traffic |
| B. ros2probe | `sudo rp run` 실행 | passive capture runtime이 participant를 만들지 않는지 확인 |
| C. ros2 daemon | `ros2 daemon start` 실행 후 유지 | daemon participant가 discovery traffic을 증가시키는지 확인 |


**반복 횟수**: scale x 조건당 10회

전체 run 수:

```text
5 graph scales x 3 observer conditions x 10 repetitions = 150 runs
```

---

## 4. 측정 지표

| 지표 | 측정 방법 | 측정 위치 |
|---|---|---|
| SPDP packet count | pcap에서 RTPS SPDP packet 수 파싱 | Laptop B NIC |
| SEDP packet count | pcap에서 RTPS SEDP packet 수 파싱 | Laptop B NIC |
| SEDP Publications count | DataWriter endpoint announcement 수 파싱 | Laptop B NIC |
| SEDP Subscriptions count | DataReader endpoint announcement 수 파싱 | Laptop B NIC |
| SEDP control count | Heartbeat/ACKNACK 등 reliable discovery control packet 수 파싱 | Laptop B NIC |
| SPDP/SEDP byte count | 해당 packet frame length 합산 | Laptop B NIC |
| Participant count | SPDP/SEDP에서 unique participant GUID prefix 추출 | Laptop B NIC |
| Laptop B participant count | Laptop B IP를 source로 하는 participant GUID count | Laptop B NIC |
| Endpoint count | SEDP에서 unique DataWriter/DataReader entity count 추출 | Laptop B NIC |

주요 비교 지표:

```text
ΔSPDP packets = packets(condition) - packets(baseline)
ΔSEDP packets = packets(condition) - packets(baseline)
Δdiscovery bytes = bytes(condition) - bytes(baseline)
Δparticipant count = participants(condition) - participants(baseline)
Δendpoint count = endpoints(condition) - endpoints(baseline)
```

---

## 5. 실험 절차

### 5.1 사전 환경 설정

Laptop A, B 공통:

```bash
source /opt/ros/humble/setup.bash
source install/setup.bash
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_DOMAIN_ID=77
ros2 daemon stop
```

Laptop B:

```bash
sudo cpupower frequency-set -g performance
```

### 5.2 1 run 절차

```
[사전]
1. Laptop A/B에서 ROS_DOMAIN_ID=77, RMW=FastDDS 설정
2. Laptop B에서 ros2 daemon stop
3. 이전 조건의 publisher, subscriber, rp run, ros2 daemon, capture process 종료 확인

[Laptop B]
4. 조건별 observer 실행
   - baseline: skip
   - ros2probe: sudo rp run
   - ros2 daemon: ros2 daemon start
5. 10s observer stabilization
6. packet capture 시작

[Laptop A]
7. scale별 publisher process 실행
   - G1/G5/G10/G20/G50 중 하나

[Laptop B]
8. scale별 subscriber process 실행
   - publisher와 가능한 한 같은 startup window에 맞춤
9. workload startup 직후 10s discovery packet capture
10. packet capture 종료
11. observer 종료
12. publisher/subscriber process 종료
13. ros2 daemon stop
14. cleanup 확인
15. 10s cooldown
```

observer를 workload보다 먼저 실행하고 10초 안정화하는 이유는 observer 자체 startup traffic과 workload discovery burst를 분리하기 위함이다. packet capture는 pub-sub workload 실행 직전에 시작해 초기 SPDP/SEDP packet을 놓치지 않도록 한다.

### 5.3 캡처 명령 예시

```bash
sudo tshark -i <NIC> \
  -f "udp portrange 7400-7600" \
  -a duration:10 \
  -w results/exp2/<scale>/<condition>/run01/discovery.pcapng
```

FastDDS 기본 RTPS discovery는 보통 UDP 7400번대 포트를 사용한다. 최종 분석은 capture filter가 아니라 pcap 내 RTPS dissector 결과를 기준으로 한다.

---

## 6. 결과 디렉토리 구조

```
results/exp2/
├── G1/
│   ├── baseline/
│   │   └── run01~10/
│   │       ├── discovery.pcapng
│   │       ├── summary.csv
│   │       └── obs.log
│   ├── rp_run/
│   │   └── run01~10/
│   └── ros2_daemon/
│       └── run01~10/
├── G5/
├── G10/
├── G20/
└── G50/
```

| 파일 | 내용 |
|---|---|
| discovery.pcapng | workload startup 직후 10초 RTPS/DDS packet capture |
| summary.csv | run별 SPDP/SEDP packet, byte, participant/endpoint count 요약 |
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

### 7.3 Endpoint count

SEDP Publications와 SEDP Subscriptions에서 endpoint entity를 분리해 DataWriter/DataReader 수를 계산한다. G scale별 expected endpoint count는 baseline 기준으로 G1=2, G5=10, G10=20, G20=40, G50=100이다. `ros2_daemon` 조건에서 endpoint count가 추가로 증가하면 daemon이 생성한 DDS endpoint를 별도로 보고한다.

보고 지표:

| 비교 | 보고 지표 |
|---|---|
| `ros2_daemon` vs baseline | Δparticipant count, ΔSPDP/SEDP packets, Δdiscovery bytes |
| `rp_run` vs baseline | Δparticipant count, ΔSPDP/SEDP packets, Δdiscovery bytes |
| `ros2_daemon` vs `rp_run` | discovery overhead 차이 |
| scale trend | G1/G5/G10/G20/G50에 따른 observer overhead 증가 양상 |

### 7.4 기대 결과

| 조건 | 예상 participant 증가 | 예상 discovery traffic 증가 |
|---|---|---|
| baseline | 없음 | 기준값 |
| rp_run | 없음 | 기준값 근처 |
| ros2_daemon | 있음 | 증가 |

scale이 커질수록 baseline discovery traffic도 증가한다. 특히 pub-sub pair 수가 증가하면 SPDP participant announcement뿐 아니라 SEDP Publications/Subscriptions 및 reliable discovery control traffic도 증가한다. 핵심 평가는 각 scale 내부에서 `rp_run - baseline`과 `ros2_daemon - baseline`을 비교하는 것이다.

---

## 8. 유효성 기준

| 조건 | valid 기준 |
|---|---|
| baseline | Laptop B에서 ROS graph observer process 없음, `ros2 daemon stop` 상태 |
| rp_run | `rp run` socket ready, ROS 2 node/participant 생성 없음 |
| ros2_daemon | `ros2 daemon start` 성공, run 종료 후 `ros2 daemon stop` 수행 |
| workload | scale에 맞는 publisher/subscriber process 수가 실행됨 |
| pcap | 10초 capture 존재, workload startup 시점 포함, RTPS packet 파싱 가능 |

`rp discover`는 active discovery trigger이므로 이 실험의 ros2probe 조건에 포함하지 않는다.
