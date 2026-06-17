# AI Storage 통합 패키지 설치 가이드

## 1. 패키지 목적

고효율 서버에서 검증된 다음 구성을 다른 기관 서버에 동일하게 설치하기 위한 통합 패키지이다.

- AI Storage Mutating Admission Webhook (Pod 주입 + PVC tier 주입)
- 커스텀 스케줄러 `ai-storage-scheduler`
- 오케스트레이터 `ai-storage-orchestrator` (Pod migration)
- `insight-trace` sidecar (메인 컨테이너 종료 감지 버전: `ketidevit2/insight-trace:job-exit-20260527`)
- 논리 StorageClass `storage-l1` / `storage-l2` / `storage-l3` / `storage-s3`
- CIFAR-10 워크로드 4종 (preprocessing / training / inference / checkpoint-io)
- 추가 전처리 워크로드 3종 (image-augmentation / annotation-index / tensor-shard)
- scenario1 / scenario2 검증 스크립트

패키지 디렉터리를 다른 서버에 복사한 뒤 `./setup.sh` 한 번으로 설치할 수 있도록 구성했다.

## 2. 대상 서버 사전 조건

- Kubernetes 1.25+
- `kubectl` 가 cluster admin 권한으로 접근 가능
- `openssl`, `sed`, `base64` 명령
- 컨테이너 런타임: containerd (`ctr -n k8s.io images import` 지원) 또는 Docker
- 폐쇄망 운영 시: 미리 인터넷 가능 머신에서 `images/save-images.sh` 로 tar 를 만들어 두어야 한다.
- GPU 워크로드까지 검증할 경우: `nvidia.com/gpu` 가 노출되는 노드 (없어도 패키지 자체는 동작한다 — `verify.sh` 가 안내만 출력).
- StorageClass `storage-l1/l2/l3/s3` 의 provisioner 는 `cluster.local/nfs-subdir-external-provisioner` 로 설정되어 있다. NFS provisioner 또는 동일 이름의 CSI 가 사전에 배포되어 있어야 한다.

## 3. 이미지 준비 방법

### 인터넷 가능 build 머신에서 tar 생성

```bash
./images/save-images.sh
ls -lh images/tar/
```

`image-list.txt` 의 각 줄에 명시된 tar 파일이 `images/tar/` 에 생성된다.

### 폐쇄망 대상 서버에서 import

`setup.sh` 가 `IMPORT_IMAGES=true` 일 때 자동으로 `images/import-images.sh` 를 호출한다. 수동 실행도 가능하다.

```bash
CONTAINER_RUNTIME=auto ./images/import-images.sh
# 또는
CONTAINER_RUNTIME=ctr ./images/import-images.sh images/tar
CONTAINER_RUNTIME=docker ./images/import-images.sh images/tar
```

> `ai-storage-orchestrator:latest` 는 `imagePullPolicy: Never` 이므로 폐쇄망 import 가 필수다.

## 4. 설치 방법

```bash
cp env.example env
vi env             # TARGET_NAMESPACE, APPLY_WORKLOAD_EXAMPLES 등 조정
set -a; source env; set +a
./setup.sh
```

기본 설치 동작:

1. Namespace `ai-storage-workloads` 생성 + `keti-ai-storage-injection=enabled` 라벨 부착
2. StorageClass `storage-l1/l2/l3/s3` 적용
3. Webhook 자체 서명 인증서 생성 → `ai-storage-webhook-tls` Secret → `webhook-deployment` → `MutatingWebhookConfiguration` (caBundle 치환) 적용
4. Scheduler / Orchestrator 적용
5. 세 Deployment rollout 대기 (각 180s)
6. `APPLY_WORKLOAD_EXAMPLES=true` 일 때만 워크로드 예제 apply

## 5. 검증 방법

```bash
./verify.sh
```

다음 항목을 검사한다.

- Namespace `keti-ai-storage-injection=enabled` 라벨
- StorageClass storage-l1/l2/l3/s3 존재
- Deployment ready (`ai-storage-webhook` / `ai-storage-scheduler` / `ai-storage-orchestrator`)
- MutatingWebhookConfiguration 존재 및 webhook 수
- GPU 노드 존재 여부 (없으면 GPU 워크로드 건너뛰기 안내)
- `APPLY_WORKLOAD_EXAMPLES=true` 일 때 PVC selected-tier 값

## 6. 워크로드 예제 실행 방법

### 옵션 A. setup.sh 한 번에

```bash
APPLY_WORKLOAD_EXAMPLES=true ./setup.sh
```

### 옵션 B. 개별 apply

```bash
kubectl apply -f manifests/05-workloads/cifar10/
kubectl apply -f manifests/05-workloads/preprocessing/
kubectl get pvc -n ai-storage-workloads \
  -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,TIER:.metadata.annotations.ai-storage/selected-tier
kubectl get job -n ai-storage-workloads
```

### scenario 스크립트

```bash
./scripts/run-scenario1.sh    # 전처리 → webhook → PVC binding → scheduler → 결과 확인
./scripts/run-scenario2.sh    # node forecaster → policy → orchestrator → migration 비교
./scripts/run-demo-all.sh
```

## 7. CSD / 물리 tier 분리 주의사항

`docs/CSD-tier-notes.md` 참조. 현재 패키지의 StorageClass 네 개는 동일 NFS provisioner 를 사용하므로 **논리 tier 선정**만 검증된다. 실제 L1/L2/L3/S3 물리 backend 분리는 기관별 CSD/NFS/CSI 매핑이 별도로 필요하다.

## 8. Rollback / Uninstall 방법

```bash
./uninstall.sh                                          # 안내 메시지만 출력 (안전 모드)
DELETE_WORKLOADS=true ./uninstall.sh                    # 워크로드 예제 Job 제거 (PVC 는 남김)
DELETE_CORE=true ./uninstall.sh                         # webhook / scheduler / orchestrator 제거
DELETE_STORAGECLASS=true ./uninstall.sh                 # storage-l1/l2/l3/s3 제거 (다른 워크로드 영향 주의)
DELETE_NAMESPACE=true ./uninstall.sh                    # TARGET_NAMESPACE 제거 (남아있는 PVC/Pod 종속 삭제)
```

- PV 는 `reclaimPolicy: Retain` 이므로 자동 삭제되지 않는다. `kubectl get pv` 로 확인 후 운영자가 수동으로 정리한다.
- `metrics-server`, NFS provisioner, GPU device plugin 등 인프라 의존성은 본 스크립트가 삭제하지 않는다.

## 9. 알려진 제한사항

- StorageClass `storage-l1/l2/l3/s3` 가 동일 NFS provisioner 를 쓰기 때문에 실제 성능 분리는 검증되지 않았다 (논리 tier 선정만 검증). 자세한 내용은 `docs/CSD-tier-notes.md`.
- `ai-storage-orchestrator` 이미지가 `imagePullPolicy: Never` 이며 공개 레지스트리에 푸시되어 있지 않다. 폐쇄망에서는 사전 import 가 반드시 필요하다.
- Webhook 인증서는 `setup.sh` 가 매 실행마다 새로 생성한다. 외부에서 발급한 CA 를 쓰려면 `manifests/02-webhook/generate-certs.sh` 와 `webhook-config.yaml` 의 `<CA_BUNDLE>` 치환 부분을 별도로 처리해야 한다.
- migration 상태는 Orchestrator 메모리에만 보존된다. Pod 재시작 시 in-flight migration 은 유실된다.
- 10.0.4.250 CSD 노드 직접 점검은 SSH 인증 문제로 본 검증 사이클에서 미완료이다 (`docs/CSD-tier-notes.md` 참조).
