# KETI Infrastructure

KETI AI Storage System의 공용 인프라 구성 요소들을 관리합니다.

## 구조

```
keti-infrastructure/
├── kafka/                  # Apache Kafka (Strimzi)
│   ├── namespace.yaml      # kafka 네임스페이스
│   ├── kafka-cluster.yaml  # Kafka 클러스터 정의
│   └── topics.yaml         # KETI용 토픽 정의
└── monitoring/             # 모니터링 도구
    └── dcgm-exporter.yaml  # NVIDIA GPU 메트릭 수집
```

## 배포 순서

### 1. Strimzi Operator 설치 (최초 1회)

```bash
kubectl create namespace kafka
kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka

# Operator 준비 대기
kubectl wait deployment/strimzi-cluster-operator --for=condition=Available -n kafka --timeout=300s
```

### 2. Kafka 클러스터 배포

```bash
kubectl apply -f kafka/kafka-cluster.yaml

# 클러스터 준비 대기
kubectl wait kafka/keti-kafka --for=condition=Ready -n kafka --timeout=300s
```

### 3. Kafka 토픽 생성

```bash
kubectl apply -f kafka/topics.yaml
```

### 4. GPU 모니터링 배포

```bash
kubectl apply -f monitoring/dcgm-exporter.yaml
```

## 서비스 엔드포인트

| 서비스 | 엔드포인트 | 용도 |
|--------|-----------|------|
| Kafka (plain) | `keti-kafka-kafka-bootstrap.kafka:9092` | 메시지 송수신 |
| Kafka (TLS) | `keti-kafka-kafka-bootstrap.kafka:9093` | 암호화 통신 |
| DCGM Exporter | `dcgm-exporter.gpu-monitoring:9400` | GPU 메트릭 |

## Kafka 토픽

| 토픽명 | 파티션 | 보관기간 | 용도 |
|--------|--------|----------|------|
| gpu-metrics | 3 | 7일 | GPU 사용률, 온도, 메모리 |
| storage-metrics | 3 | 7일 | 스토리지 I/O 메트릭 |
| pod-events | 3 | 3일 | 파드 생성/삭제/마이그레이션 |
| scheduling-decisions | 1 | 7일 | 스케줄링 결정 로그 |

## 확인 명령어

```bash
# Kafka 상태
kubectl get kafka -n kafka
kubectl get kafkatopic -n kafka

# DCGM 상태
kubectl get pods -n gpu-monitoring
```
