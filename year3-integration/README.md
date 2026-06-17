# Year 3 Integration - KETI AI Storage Platform

이 디렉토리는 **3차년도 통합** 관련 내용을 담고 있습니다.
KETI AI Storage Platform의 전체 설치 및 테스트 스크립트가 포함되어 있습니다.

## Project Context

### 연구 과제 정보
- **과제명**: AI 연산 가속기 최적화 고효율 병렬 스토리지 SW기술 개발
- **지원**: IITP (정보통신기획평가원), 과학기술정보통신부
- **과제번호**: RS-2024-00461572

### 핵심 혁신 기술
1. **CSD (Computational Storage Device)** 자원을 Kubernetes 스케줄링에 통합
2. **최적화된 Pod 마이그레이션**: 완료된 컨테이너 제외로 CPU 50%, Memory 40% 절감
3. **정책 기반 자율 오케스트레이션**: 6가지 정책 타입 자동 실행

---

## System Architecture (시스템 아키텍처)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         KETI AI Storage Platform                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐       │
│  │  Insight Scope  │────▶│  Insight Trace  │────▶│ Node Resource   │       │
│  │  (메트릭 수집)   │     │  (분산 추적)     │     │ Forecaster      │       │
│  └─────────────────┘     └─────────────────┘     │ (자원 예측)      │       │
│                                                   └────────┬────────┘       │
│                                                            │                │
│                                                            ▼                │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                  Orchestration Policy Engine                         │   │
│  │  ┌─────────────────────────────────────────────────────────────┐    │   │
│  │  │ OrchestrationPolicy CRD (6가지 정책 타입)                    │    │   │
│  │  │ - migration: 티어 마이그레이션                               │    │   │
│  │  │ - scaling: 오토스케일링                                      │    │   │
│  │  │ - provisioning: 사전 프로비저닝                              │    │   │
│  │  │ - caching: 글로벌 캐싱                                       │    │   │
│  │  │ - loadbalance: 로드밸런싱                                    │    │   │
│  │  │ - preemption: 선점                                           │    │   │
│  │  └─────────────────────────────────────────────────────────────┘    │   │
│  └──────────────────────────────┬──────────────────────────────────────┘   │
│                                 │                                           │
│                                 ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    AI Storage Orchestrator                           │   │
│  │  (6가지 Operator 실행: Migration, AutoScaling, Loadbalance,         │   │
│  │   Caching, Provision, Preemption)                                    │   │
│  └──────────────────────────────┬──────────────────────────────────────┘   │
│                                 │                                           │
│                                 ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    AI Storage Scheduler                              │   │
│  │  (CSD/GPU 인식 커스텀 스케줄러, schedulerName: ai-storage-scheduler) │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

외부 연동:
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   ArgoCD     │  │  Kubeflow    │  │    Kueue     │
│ (GitOps CD)  │  │ (ML Training)│  │ (Job Queue)  │
└──────────────┘  └──────────────┘  └──────────────┘
```

---

## Data Flow (데이터 플로우)

### 정책 기반 오케스트레이션 플로우

```
1. 메트릭 수집
   Insight Scope → Prometheus 메트릭 수집 → 노드/Pod 상태 모니터링

2. 자원 예측
   Node Resource Forecaster → 시계열 예측 → CPU/Memory/Storage 사용량 예측

3. 정책 생성
   Forecaster의 예측값 기반 → OrchestrationPolicy CRD 생성
   예: CPU 사용량 80% 초과 예측 시 → scaling 정책 자동 생성

4. 정책 실행 (autoExecute: true인 경우)
   Policy Engine Controller → ai-storage-orchestrator API 호출

   POST /api/v1/migrations    → Migration Operator
   POST /api/v1/autoscaling   → AutoScaling Operator
   POST /api/v1/provisioning  → Provision Operator
   POST /api/v1/caching       → Caching Operator
   POST /api/v1/loadbalancing → Loadbalance Operator
   POST /api/v1/preemption    → Preemption Operator

5. 결과 업데이트
   Operator 실행 결과 → OrchestrationPolicy status 업데이트
   phase: Pending → Approved → Executing → Completed/Failed
```

---

## Component Details (컴포넌트 상세)

### Apollo 컴포넌트 (자체 개발)

| Component | Namespace | Port | 역할 | 소스 위치 |
|-----------|-----------|------|------|----------|
| insight-scope | apollo | 8080 | Prometheus 메트릭 수집 | /root/workspace/insight-scope |
| insight-trace | apollo | 8080 | 분산 추적 (Jaeger 연동) | /root/workspace/insight-trace |
| node-resource-forecaster | apollo | 8080 | 시계열 자원 예측 | /root/workspace/apollo/node-resource-forecaster |
| orchestration-policy-engine | apollo | 8080 | 정책 CRD 컨트롤러 | /root/workspace/apollo/orchestration-policy-engine |
| ai-storage-scheduler | keti | - | CSD/GPU 인식 스케줄러 | /root/workspace/ai-storage-scheduler |
| ai-storage-orchestrator | kube-system | 8080 | 6가지 Operator 실행 | /root/workspace/ai-storage-orchestrator |

### 외부 연동 컴포넌트

| Component | Namespace | 용도 |
|-----------|-----------|------|
| ArgoCD | argocd | GitOps 기반 CD, Apollo 컴포넌트 배포 자동화 |
| Kubeflow | kubeflow | ML Training (PyTorchJob, TFJob) |
| Kueue | kueue-system | Job Queuing, ResourceFlavor 기반 자원 할당 |

---

## CRD (Custom Resource Definitions)

### OrchestrationPolicy CRD
```yaml
apiVersion: apollo.keti.re.kr/v1alpha1
kind: OrchestrationPolicy
metadata:
  name: example-policy
  namespace: apollo
spec:
  policyType: migration|scaling|provisioning|caching|loadbalance|preemption
  priority: 1-100 (높을수록 우선)
  autoExecute: true|false
  targetWorkload:
    name: workload-name
    namespace: default
    kind: Deployment|StatefulSet|Job
  conditions:
    triggers:
    - type: threshold|prediction|manual
      metric: cpu_usage|memory_usage|io_latency|...
      threshold: "80"
  actions:
    migration: { sourceNode, targetNode, preservePV, timeout }
    scaling: { minReplicas, maxReplicas, targetCPU, targetMemory }
    provisioning: { storageSize, storageClass, accessMode }
    caching: { sourcePVC, sourceNamespace, targetTier, cacheSize }
    loadbalance: { targetNode, strategy, weight }
    preemption: { priority, reason, graceperiod }
status:
  phase: Pending|Approved|Executing|Completed|Failed
  result: operator-id
  lastUpdated: timestamp
```

### Kueue ResourceFlavors
```yaml
# 설치 시 자동 생성되는 ResourceFlavor
- default-flavor: 일반 CPU 노드
- gpu-flavor: GPU 노드 (nvidia.com/gpu)
- csd-flavor: CSD 노드 (keti.re.kr/csd)
```

---

## Kubernetes 노드 라벨링

```bash
# Master Node
kubectl label nodes <master> layer=orchestration
kubectl label nodes <master> node-role.kubernetes.io/control-plane=

# Compute Node (GPU 워크로드)
kubectl label nodes <worker> layer=compute
kubectl label nodes <worker> node-role.kubernetes.io/worker=

# Storage Node (CSD 장치)
kubectl label nodes <storage> layer=storage
kubectl label nodes <storage> node-role.kubernetes.io/worker=
```

---

## Directory Structure

```
year3-integration/
├── README.md                          # 이 파일 (통합 정보)
├── 1.setup/                           # 설치 스크립트 (순서대로 실행)
│   ├── common.sh                      # 공유 유틸리티 (로깅)
│   ├── 01.install-prerequisites.sh    # Docker, Go 1.21+, Helm, kubectl
│   ├── 02.install-kubernetes.sh       # kubeadm, kubelet, kubectl v1.30
│   ├── 03.init-cluster-master.sh      # 마스터 초기화 + Calico CNI
│   ├── 03.join-cluster-worker.sh      # 워커 노드 조인
│   ├── 04.install-storage.sh          # NFS Provisioner
│   ├── 05.install-argocd.sh           # ArgoCD + CLI
│   ├── 06.install-kubeflow.sh         # Kubeflow Training Operator
│   ├── 07.install-kueue.sh            # Kueue + ResourceFlavors + LocalQueues
│   ├── 08.install-apollo-components.sh # 모든 Apollo 컴포넌트 (Docker Hub에서)
│   └── 09.verify-integration.sh       # 전체 검증
│
└── 2.test_shell/                      # 테스트 스크립트
    ├── common.sh                      # 테스트 유틸리티
    ├── 01.test-kubernetes.sh          # K8s 클러스터 헬스
    ├── 02.test-argocd.sh              # ArgoCD 기능 테스트
    ├── 03.test-kubeflow.sh            # PyTorchJob 테스트
    ├── 04.test-kueue.sh               # Kueue 워크로드 테스트
    ├── 05.test-apollo.sh              # Apollo 컴포넌트 테스트
    ├── 06.test-full-integration.sh    # 전체 통합 테스트
    └── 07.test-policy-orchestration.sh # 6가지 정책 테스트
```

---

## Docker Images (Docker Hub)

모든 Apollo 컴포넌트는 **Docker Hub**에서 배포됩니다 (빌드 불필요):

```bash
# Registry
DOCKER_REGISTRY="ketidevit2"

# Images
ketidevit2/insight-scope:latest
ketidevit2/insight-trace:latest
ketidevit2/node-resource-forecaster:latest
ketidevit2/orchestration-policy-engine:latest
ketidevit2/keti-ai-storage-scheduler:latest
ketidevit2/ai-storage-orchestrator:latest
```

### 이미지 빌드 및 푸시 (개발 시)
```bash
# 각 컴포넌트 디렉토리에서
cd /root/workspace/apollo/<component>
./scripts/1.build-image.sh    # 빌드 + Docker Hub 푸시
./scripts/2.apply-deployment.sh apply  # K8s 배포
```

---

## API Endpoints

### AI Storage Orchestrator (kube-system namespace)
```
GET  /health                    # 헬스 체크
POST /api/v1/migrations         # 마이그레이션 시작
GET  /api/v1/migrations/:id     # 마이그레이션 상태
POST /api/v1/autoscaling        # 오토스케일링 설정
POST /api/v1/provisioning       # 프로비저닝 시작
POST /api/v1/caching            # 캐싱 설정
POST /api/v1/loadbalancing      # 로드밸런싱 설정
POST /api/v1/preemption         # 선점 시작
```

### Node Resource Forecaster (apollo namespace)
```
GET  /health                    # 헬스 체크
GET  /api/v1/forecast/:node     # 노드별 자원 예측
POST /api/v1/predict            # 예측 요청
```

---

## Installation (설치)

### 새 Ubuntu VM에 설치 (순서대로)
```bash
cd /root/workspace/year3-integration/1.setup

./01.install-prerequisites.sh    # Docker, Go, Helm
./02.install-kubernetes.sh       # K8s 패키지
./03.init-cluster-master.sh      # 클러스터 초기화 (마스터만)
./04.install-storage.sh          # 스토리지
./05.install-argocd.sh           # ArgoCD
./06.install-kubeflow.sh         # Kubeflow
./07.install-kueue.sh            # Kueue
./08.install-apollo-components.sh # Apollo (Docker Hub에서 pull)
./09.verify-integration.sh       # 검증
```

### 워커 노드 조인
```bash
./01.install-prerequisites.sh
./02.install-kubernetes.sh
./03.join-cluster-worker.sh --token <token> --hash <hash> --master <ip>
```

---

## Testing (테스트)

### 개별 테스트
```bash
cd /root/workspace/year3-integration/2.test_shell

./01.test-kubernetes.sh           # K8s 헬스
./02.test-argocd.sh               # ArgoCD
./03.test-kubeflow.sh             # Kubeflow PyTorchJob
./04.test-kueue.sh                # Kueue 워크로드
./05.test-apollo.sh               # Apollo 컴포넌트
./07.test-policy-orchestration.sh # 6가지 정책 테스트
```

### 전체 통합 테스트
```bash
./06.test-full-integration.sh
```

---

## Logs & Troubleshooting

### 설치 로그
```bash
ls -la /var/log/keti-setup/
cat /var/log/keti-setup/08.install-apollo-components.log
```

### 컴포넌트 로그
```bash
# Policy Engine
kubectl logs -n apollo -l app=orchestration-policy-engine -f

# Orchestrator
kubectl logs -n kube-system -l app=ai-storage-orchestrator -f

# Scheduler
kubectl logs -n keti -l app=ai-storage-scheduler -f
```

### 상태 확인
```bash
kubectl get pods -A | grep -E "apollo|keti|ai-storage"
kubectl get orchestrationpolicies -n apollo
kubectl get clusterqueues
kubectl get localqueues -A
```

---

## Related Source Directories

```
/root/workspace/
├── ai-storage-scheduler/           # 커스텀 스케줄러
├── ai-storage-orchestrator/        # 6가지 Operator
├── ai-storage-metric-collector/    # 메트릭 수집기
├── apollo/
│   ├── orchestration-policy-engine/  # 정책 엔진 (Kubebuilder)
│   └── node-resource-forecaster/     # 자원 예측
├── insight-scope/                  # 메트릭 수집
├── insight-trace/                  # 분산 추적
└── year3-integration/              # 이 디렉토리 (통합 스크립트)
```

---

## Version Info

- Kubernetes: 1.30
- Go: 1.21+
- Kubeflow: Training Operator v1.7+
- Kueue: v0.6.2
- ArgoCD: v2.9+
- Calico CNI: v3.26+

---

## Research Context

이 시스템은 IITP 지원 연구 과제의 3차년도 결과물입니다:
- **목표**: AI 연산 가속기에 최적화된 고효율 병렬 스토리지 SW 기술 개발
- **핵심**: CSD 자원 통합, 정책 기반 자율 오케스트레이션, 최적화된 Pod 마이그레이션
