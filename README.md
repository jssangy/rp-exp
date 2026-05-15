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
sudo cpupower frequency-set -g performance
ros2 daemon stop
```

---

## 실험 실행

### Experiment 1

```bash
# Laptop A (Publisher)
./scripts/run_exp1_pub.sh --sync <Laptop-B-wlan-IP>

# Laptop B (Subscriber)
./scripts/run_exp1_sub.sh --sync <Laptop-A-wlan-IP>
```

### Experiment 3

두 장비 모두 빌드 후 `install/setup.bash`를 source한 상태에서 실행한다.

```bash
# Publisher Host
./scripts/run_exp3_pub.sh --sync <Receiver-IP>

# Receiver Platform
./scripts/run_exp3_sub.sh --sync <Publisher-IP> --platform <pc|rpi|jetson>
```

일부 시나리오만 짧게 확인할 때:

```bash
./scripts/run_exp3_sub.sh --sync <Publisher-IP> --platform pc --scenarios ST100 --runs 1
```

기본 설정:

```text
scenarios: ST100, ST500, ST1000
conditions: baseline, rp_hz, topic_hz
runs: 10
results: results/exp3/<platform>/<scenario>/<condition>/runXX/
```

---

## 개별 노드 실행 명령어

### S1 — `/cmd_vel`
```bash
ros2 run test s1_pub
ros2 run test s1_sub
```

### S2 — `/imu`
```bash
ros2 run test s2_pub
ros2 run test s2_sub
```

### S3-a — `/scan`
```bash
ros2 run test s3a_pub
ros2 run test s3a_sub
```

### S3-b — `/points` (16ch, 30,000 pts)
```bash
ros2 run test s3_points_pub 30000
ros2 run test s3_points_sub
```

### S3-c — `/points` (64ch, 130,000 pts)
```bash
ros2 run test s3_points_pub 130000
ros2 run test s3_points_sub
```

### S4-a — `/image_raw/compressed`
```bash
ros2 run test s4a_pub
ros2 run test s4a_sub
```

### S4-b — `/depth/image_raw`
```bash
ros2 run test s4_image_pub
ros2 run test s4_image_sub
```

### S5-a — 실내 AMR 복합
```bash
ros2 launch test s5a_pub.launch.py
ros2 launch test s5a_sub.launch.py
```

### S5-b — 자율주행 고대역 복합
```bash
ros2 launch test s5b_pub.launch.py
ros2 launch test s5b_sub.launch.py
```
