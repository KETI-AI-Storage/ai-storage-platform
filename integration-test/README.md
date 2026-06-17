# KETI AI Storage System - Integration Test

이 디렉토리는 KETI AI Storage System의 전체 컴포넌트 통합 테스트를 위한 환경입니다.

## 시스템 아키텍처

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         KETI AI Storage System                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐       │
│  │  insight-trace  │────▶│     APOLLO      │────▶│  ai-storage-    │       │
│  │   (Sidecar)     │     │ Policy Server   │     │   scheduler     │       │
│  │                 │     │   (port 50051)  │     │                 │       │
│  │ WorkloadSignature     └────────┬────────┘     └────────┬────────┘       │
│  └─────────────────┘              │                       │                │
│                                   │                       │                │
│  ┌─────────────────┐              │              ┌────────▼────────┐       │
│  │  insight-scope  │              │              │   Kubernetes    │       │
│  │  (Deployment)   │              │              │     API         │       │
│  │                 │              │              └────────┬────────┘       │
│  │ ClusterInsight  │              │                       │                │
│  └────────┬────────┘              │              ┌────────▼────────┐       │
│           │                       │              │  ai-storage-    │       │
│           └───────────────────────┘              │  orchestrator   │       │
│                                                  │   (Migration)   │       │
│                                                  └─────────────────┘       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 데이터 흐름

1. **insight-trace (Sidecar)**: AI 워크로드 Pod와 함께 실행되어 I/O 패턴 분석
2. **insight-scope**: 클러스터 전체 리소스 상태 모니터링
3. **APOLLO**: 수집된 데이터로 스케줄링/오케스트레이션 정책 생성
4. **ai-storage-scheduler**: APOLLO 정책 기반 Pod 스케줄링
5. **ai-storage-orchestrator**: 필요시 Pod 마이그레이션 수행

## 테스트 워크로드

| 파일 | 워크로드 타입 | 설명 |
|------|--------------|------|
| `01-ai-training-job.yaml` | Training | LLaMA 모델 학습 시뮬레이션 |
| `02-ai-inference-deployment.yaml` | Inference | GPT 추론 서비스 시뮬레이션 |
| `03-data-preprocessing-job.yaml` | Preprocessing | 데이터 전처리 작업 시뮬레이션 |

## 실행 방법

### 1. 시스템 컴포넌트 확인

```bash
# 모든 시스템 컴포넌트가 실행 중인지 확인
kubectl get pods -n keti
kubectl get pods -n kube-system | grep ai-storage
```

### 2. 통합 테스트 실행

```bash
# 전체 테스트 실행
./scripts/run-test.sh

# 현재 상태 확인
./scripts/run-test.sh status

# 테스트 리소스 정리
./scripts/run-test.sh cleanup
```

### 3. 개별 워크로드 배포

```bash
# 네임스페이스 생성
kubectl apply -f 00-namespace.yaml

# 워크로드 배포
kubectl apply -f workloads/01-ai-training-job.yaml
kubectl apply -f workloads/02-ai-inference-deployment.yaml
kubectl apply -f workloads/03-data-preprocessing-job.yaml
```

## 검증 항목

### 1. 스케줄링 검증
```bash
# Pod가 ai-storage-scheduler로 스케줄링되었는지 확인
kubectl get pods -n ai-workload-test -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.schedulerName} -> {.spec.nodeName}{"\n"}{end}'
```

### 2. Insight-Trace 동작 확인
```bash
# Sidecar 로그 확인
kubectl logs -n ai-workload-test <pod-name> -c insight-trace
```

### 3. APOLLO 수신 데이터 확인
```bash
# APOLLO 로그에서 WorkloadSignature 수신 확인
kubectl logs -n keti -l app.kubernetes.io/name=apollo-policy-server | grep "WorkloadSignature"
```

### 4. 스케줄러 로그 확인
```bash
# 스케줄링 결정 로그 확인
kubectl logs -n keti -l app.kubernetes.io/name=ai-storage-scheduler
```

## 예상 결과

1. **Pod 스케줄링**: 모든 테스트 Pod가 `ai-storage-scheduler`에 의해 스케줄링됨
2. **Sidecar 실행**: 각 Pod에서 `insight-trace` 컨테이너가 정상 실행
3. **데이터 전송**: `insight-trace`가 APOLLO로 WorkloadSignature 전송
4. **정책 생성**: APOLLO가 수신 데이터 기반으로 정책 생성

## 트러블슈팅

### Pod가 Pending 상태로 유지되는 경우
```bash
# Pod 이벤트 확인
kubectl describe pod -n ai-workload-test <pod-name>

# 스케줄러 로그 확인
kubectl logs -n keti -l app.kubernetes.io/name=ai-storage-scheduler --tail=50
```

### Sidecar가 APOLLO에 연결 실패하는 경우
```bash
# APOLLO 서비스 확인
kubectl get svc -n keti apollo-policy-server

# DNS 해석 테스트
kubectl run test-dns --rm -it --image=busybox --restart=Never -- nslookup apollo-policy-server.keti.svc.cluster.local
```

## 설정 가능한 환경변수 (insight-trace)

| 환경변수 | 기본값 | 설명 |
|---------|--------|------|
| `APOLLO_ENDPOINT` | - | APOLLO gRPC 서버 주소 |
| `METRICS_INTERVAL` | 5s | 메트릭 수집 주기 |
| `ANALYSIS_INTERVAL` | 10s | 분석 주기 |
| `REPORT_INTERVAL` | 30s | APOLLO 보고 주기 |
