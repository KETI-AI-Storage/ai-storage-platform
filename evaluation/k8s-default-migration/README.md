# Kubernetes Pod Migration Module

K8s는 기본적으로 Pod 마이그레이션 기능이 없기 때문에, Pod를 삭제한 후 다른 노드에 재생성하는 방식으로 마이그레이션을 구현한 모듈입니다.

## 프로젝트 구조

```
evaluation/k8s-default-migration/
├── pod_migration.py          # Pod 마이그레이션 메인 모듈
├── ai-workload-pod.yaml      # AI 워크로드 예시 Pod (PyTorch)
├── requirements.txt          # Python 의존성
└── README.md                 # 문서
```

## 주요 기능

- **Pod 정보 조회**: 현재 Pod의 상태, 노드, IP 등 정보 확인
- **Pod 삭제**: Grace period를 설정하여 안전하게 Pod 종료
- **Pod 재생성**: 기존 설정을 유지하면서 새로운 노드에 Pod 생성
- **노드 선택**: 특정 노드를 지정하거나 스케줄러에게 자동 선택 위임
- **상태 모니터링**: 마이그레이션 전후 상태 확인 및 검증

## 설치 방법

### 1. 의존성 설치

```bash
cd evaluation/k8s-default-migration
pip install -r requirements.txt
```

### 2. Kubernetes 설정

로컬 환경에서 실행하는 경우, `~/.kube/config` 파일이 올바르게 설정되어 있어야 합니다.

```bash
# Kubernetes 클러스터 연결 확인
kubectl cluster-info

# 네임스페이스 확인
kubectl get namespaces
```

## 사용 방법

### 1. AI 워크로드 Pod 배포

먼저 예시로 제공된 PyTorch AI 워크로드 Pod를 배포합니다:

```bash
kubectl apply -f ai-workload-pod.yaml
```

Pod 상태 확인:

```bash
kubectl get pods
kubectl describe pod pytorch-training-pod
```

### 2. 사용 가능한 노드 확인

```bash
python3 pod_migration.py --list-nodes
```

출력 예시:
```
📋 Available Nodes:
--------------------------------------------------------------------------------
  - worker-node-1: Ready (CPU: 4, Memory: 16Gi)
  - worker-node-2: Ready (CPU: 4, Memory: 16Gi)
  - worker-node-3: Ready (CPU: 8, Memory: 32Gi)
--------------------------------------------------------------------------------
```

### 3. Pod 마이그레이션 실행

#### 3-1. 자동 노드 선택 (스케줄러가 결정)

```bash
python3 pod_migration.py --pod pytorch-training-pod --namespace default
```

#### 3-2. 특정 노드로 마이그레이션

```bash
python3 pod_migration.py --pod pytorch-training-pod --target-node worker-node-2
```

#### 3-3. Grace period 지정

```bash
python3 pod_migration.py --pod pytorch-training-pod --target-node worker-node-3 --grace-period 60
```

### 4. 마이그레이션 결과 확인

마이그레이션이 완료되면 아래와 같은 정보가 출력됩니다:

```
================================================================================
🚀 Starting Pod Migration: pytorch-training-pod
================================================================================

[Step 1/5] Getting current pod information...

📌 Current Pod Info:
  - Name: pytorch-training-pod
  - Namespace: default
  - Current Node: worker-node-1
  - Status: Running
  - IP: 10.244.1.5

[Step 2/5] Backing up pod manifest...
✅ Pod manifest backed up

[Step 3/5] Checking available nodes...

📋 Available Nodes:
--------------------------------------------------------------------------------
  - worker-node-1: Ready (CPU: 4, Memory: 16Gi)
  - worker-node-2: Ready (CPU: 4, Memory: 16Gi)
--------------------------------------------------------------------------------

[Step 4/5] Deleting pod from node 'worker-node-1'...
🗑️  Deleting pod 'pytorch-training-pod' with grace period 30s...
⏳ Waiting for pod deletion...
✅ Pod deleted successfully

[Step 5/5] Recreating pod...
  Target node: worker-node-2
🎯 Target node specified: worker-node-2
🚀 Creating pod 'pytorch-training-pod'...
✅ Pod created: pytorch-training-pod
⏳ Waiting for pod 'pytorch-training-pod' to be running (timeout: 300s)...
✅ Pod is now running on node: worker-node-2

[Result] Getting new pod information...

📌 New Pod Info:
  - Name: pytorch-training-pod
  - Namespace: default
  - New Node: worker-node-2
  - Status: Running
  - IP: 10.244.2.8

================================================================================
✅ Migration SUCCESSFUL: worker-node-1 -> worker-node-2
================================================================================

🎉 Pod migration completed successfully!
```

## 명령줄 옵션

```
usage: pod_migration.py [-h] [--pod POD] [--namespace NAMESPACE]
                        [--target-node TARGET_NODE]
                        [--grace-period GRACE_PERIOD] [--list-nodes]

옵션:
  -h, --help            도움말 메시지 표시
  --pod POD             마이그레이션할 Pod 이름
  --namespace NAMESPACE Pod가 위치한 네임스페이스 (기본값: default)
  --target-node TARGET_NODE
                        대상 노드 이름 (지정하지 않으면 스케줄러가 자동 선택)
  --grace-period GRACE_PERIOD
                        Pod 종료 대기 시간(초) (기본값: 30)
  --list-nodes          사용 가능한 노드 목록만 출력
```

## 마이그레이션 프로세스

1. **현재 Pod 정보 수집**: 마이그레이션 전 Pod의 상태, 노드, 설정 정보 조회
2. **Pod 매니페스트 백업**: 재생성을 위해 현재 Pod의 전체 설정 저장
3. **노드 목록 확인**: 사용 가능한 노드 상태 확인
4. **Pod 삭제**: Grace period를 준수하여 안전하게 Pod 종료
5. **Pod 재생성**: 백업한 설정으로 새 노드에 Pod 생성
6. **상태 모니터링**: Pod가 Running 상태가 될 때까지 대기
7. **결과 검증**: 마이그레이션 성공 여부 확인

## 주의사항

### 1. 데이터 손실
- **StatefulSet이 아닌 Pod의 경우 로컬 데이터는 보존되지 않습니다**
- 중요한 데이터는 PersistentVolume(PV)이나 외부 스토리지를 사용하세요

### 2. 다운타임
- Pod 삭제 후 재생성 방식이므로 **짧은 다운타임이 발생**합니다
- 무중단 마이그레이션이 필요한 경우 ReplicaSet이나 Deployment를 사용하세요

### 3. 네트워크
- Pod IP가 변경되므로 **직접 IP로 통신하는 경우 연결이 끊어집니다**
- Service를 통한 접근을 권장합니다

### 4. 권한
- Pod 조회, 삭제, 생성 권한이 필요합니다
- RBAC 설정을 확인하세요

```bash
# 현재 권한 확인
kubectl auth can-i get pods
kubectl auth can-i delete pods
kubectl auth can-i create pods
```

## AI 워크로드 예시 (PyTorch)

제공된 `ai-workload-pod.yaml`은 PyTorch 기반의 AI 학습 워크로드 예시입니다:

**특징:**
- PyTorch 2.0.1 with CUDA 11.7
- 간단한 신경망 학습 시뮬레이션
- CPU/Memory 리소스 제한 설정
- GPU 사용 가능 시 자동 활용

**리소스 요구사항:**
- Request: CPU 1 core, Memory 2Gi
- Limit: CPU 2 cores, Memory 4Gi

## 실전 사용 시나리오

### 시나리오 1: 노드 유지보수
노드에 유지보수가 필요한 경우 해당 노드의 Pod를 다른 노드로 마이그레이션:

```bash
# 현재 worker-node-1에서 실행 중인 Pod 확인
kubectl get pods -o wide | grep worker-node-1

# Pod를 worker-node-2로 마이그레이션
python3 pod_migration.py --pod pytorch-training-pod --target-node worker-node-2
```

### 시나리오 2: 리소스 밸런싱
특정 노드에 부하가 집중된 경우 Pod를 재분배:

```bash
# 노드별 리소스 사용량 확인
kubectl top nodes

# Pod를 여유 있는 노드로 마이그레이션 (자동 선택)
python3 pod_migration.py --pod pytorch-training-pod
```

### 시나리오 3: GPU 노드로 이동
GPU가 필요한 AI 워크로드를 GPU 노드로 이동:

```bash
# GPU 노드 확인
kubectl get nodes -l gpu=true

# GPU 노드로 마이그레이션
python3 pod_migration.py --pod pytorch-training-pod --target-node gpu-worker-1
```

## 트러블슈팅

### 문제 1: Pod가 Pending 상태로 유지됨
**원인:** 대상 노드에 충분한 리소스가 없거나 노드 셀렉터가 맞지 않음

**해결:**
```bash
# Pod 상태 확인
kubectl describe pod pytorch-training-pod

# 노드 리소스 확인
kubectl top nodes
kubectl describe node worker-node-2
```

### 문제 2: 권한 오류 (Forbidden)
**원인:** RBAC 권한 부족

**해결:**
```bash
# ServiceAccount에 필요한 권한 부여
kubectl create clusterrolebinding pod-admin-binding \
  --clusterrole=edit \
  --serviceaccount=default:default
```

### 문제 3: ImagePullBackOff
**원인:** 컨테이너 이미지를 가져올 수 없음

**해결:**
```bash
# 이미지 확인
kubectl describe pod pytorch-training-pod | grep -A 5 Events

# 이미지 pull secret 설정 (private registry인 경우)
kubectl create secret docker-registry regcred \
  --docker-server=<your-registry-server> \
  --docker-username=<your-username> \
  --docker-password=<your-password>
```

## 모듈 확장 아이디어

1. **배치 마이그레이션**: 여러 Pod를 동시에 마이그레이션
2. **롤백 기능**: 마이그레이션 실패 시 원래 상태로 복원
3. **상태 체크포인트**: StatefulSet을 위한 상태 저장 및 복원
4. **메트릭 수집**: 마이그레이션 성능 및 시간 측정
5. **알림 연동**: Slack/Email로 마이그레이션 결과 통보

## 라이선스

MIT License

## 참고 자료

- [Kubernetes Official Documentation](https://kubernetes.io/docs/)
- [Kubernetes Python Client](https://github.com/kubernetes-client/python)
- [PyTorch Docker Images](https://hub.docker.com/r/pytorch/pytorch)

## 문의

공인시험 준비 화이팅하세요!
