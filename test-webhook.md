# ai-storage-webhook + `test-gpu-workload` 검증 기록

## 목표

1. `test-gpu-workload.yaml`로 워크로드(PVC + Deployment) 생성  
2. Mutating Webhook이 PVC에 **상황에 맞는 StorageClass**를 주입 (`stage=train` + `gpuCount>0` → `storage-performance`)  
3. 메타데이터에 `ai-storage/selected-tier`, `ai-storage-selected-tier` 기록

---

## `test-gpu-workload.yaml` 요약

| 항목 | 내용 |
|------|------|
| 네임스페이스 | `gpu-webhook-test` + label `keti-ai-storage-injection=enabled` |
| PVC | `storageClassName` **미지정**, labels `stage=train`, `gpuCount=1` |
| Deployment | `busybox` + 위 PVC 마운트 (GPU 디바이스 없이도 PVC/웹훅 검증 가능) |

적용:

```bash
kubectl apply -f test-gpu-workload.yaml
```

---

## 지금까지 실제로 겪은 문제 (핵심)

### 1) **클러스터에 돌아가는 웹훅 바이너리가 PVC를 모르는 버전**

`MutatingWebhookConfiguration`에 `persistentvolumeclaims`를 넣은 상태에서 PVC를 만들면 다음 오류가 났습니다:

```text
Internal error occurred: add operation does not apply: doc is missing path: "/spec/containers/-": missing value
```

**원인:** 구버전 웹훅은 요청 객체를 **항상 Pod처럼** 다루고, Pod용 JSON Patch(`/spec/containers/-` 사이드카 추가 등)를 반환합니다.  
그 패치가 **PVC**에 적용되면서 API 서버가 InternalError를 냅니다.

**조치:** 레포의 최신 코드(PVC 분기 + `createPVCPatch`)로 **이미지를 다시 빌드**하고, **웹훅 Pod가 그 이미지를 실제로 쓰게** 배포해야 합니다.

### 2) **`imagePullPolicy: Never` → 로컬에서 빌드한 이미지가 노드에 없으면 갱신 안 됨**

`ai-storage-webhook` Deployment는 `ketidevit2/ai-storage-webhook:latest` + `imagePullPolicy: Never` 패턴입니다.  
개발 PC에서 `docker build`만 하고 **컨트롤 플레인/실행 노드의 containerd/docker에 이미지를 넣지 않으면**, 재시작해도 **옛 바이너리**가 그대로입니다.

### 3) **MutatingWebhookConfiguration에 PVC 규칙이 없었음**

처음 클러스터 상태:

```text
resources: ["pods"]   # persistentvolumeclaims 없음
```

PVC 생성 시 웹훅이 아예 호출되지 않습니다.

**조치:** 아래 중 하나로 `persistentvolumeclaims`를 rules에 추가 (기존 `caBundle`은 건드리지 않도록 `kubectl patch` 권장).

### 4) **티어용 StorageClass가 클러스터에 없었음**

`storage-performance` 등 4종이 없으면, 웹훅이 SC를 주입해도 PVC는 **프로비저닝 실패**할 수 있습니다.

**조치 (이번에 클러스터에 적용함):**

```bash
kubectl apply -f ai-storage-scheduler/storageClass/storageclass-performance.yaml \
  -f ai-storage-scheduler/storageClass/storageclass-capacity.yaml \
  -f ai-storage-scheduler/storageClass/storageclass-burst.yaml \
  -f ai-storage-scheduler/storageClass/storageclass-archive.yaml
```

### 5) **웹훅이 꺼져 있거나 PVC 규칙이 없을 때: Default StorageClass가 먼저 붙음**

웹훅이 PVC를 건드리지 못하면, 클러스터 **default StorageClass**(예: `nfs-client`)가 붙습니다.

**이번 관측 (MWC를 `pods`만으로 되돌린 뒤 PVC 재적용):**

```text
NAME            STATUS   STORAGECLASS
gpu-test-data   Bound    nfs-client
```

`kubectl get pvc -n gpu-webhook-test gpu-test-data -o yaml` 상 일부:

```yaml
spec:
  storageClassName: nfs-client
```

→ **`ai-storage/selected-tier` annotation 없음** (웹훅 미적용 또는 구버전).

---

## PVC 웹훅을 켠 뒤 “성공”했을 때 기대 출력

MWC에 `persistentvolumeclaims` 포함 + **최신 웹훅 이미지** 배포 후, 동일 PVC를 다시 만들면 예시는 다음과 같습니다.

```bash
kubectl get pvc -n gpu-webhook-test gpu-test-data -o wide
# STORAGECLASS 컬럼: storage-performance (train+gpuCount 규칙)

kubectl get pvc -n gpu-webhook-test gpu-test-data -o jsonpath='{.metadata.annotations.ai-storage\/selected-tier}{"\n"}'
# performance

kubectl get pvc -n gpu-webhook-test gpu-test-data -o jsonpath='{.metadata.labels.ai-storage-selected-tier}{"\n"}'
# performance
```

---

## 권장 운영 순서 (한 번에 맞추기)

1. **StorageClass 4종 적용** (위 `kubectl apply` 블록)  
2. **웹훅 이미지 빌드** (레포 `ai-storage-webhook`):

   ```bash
   cd ai-storage-webhook
   docker build -t ketidevit2/ai-storage-webhook:latest .
   ```

3. **이미지를 웹훅 Pod가 도는 노드에 로드**  
   - 환경별: `kind load docker-image …`, `ctr -n k8s.io images import …`, 노드에서 `docker load` 등  
4. **Deployment 롤링 재시작**

   ```bash
   kubectl rollout restart deployment/ai-storage-webhook -n keti
   kubectl rollout status deployment/ai-storage-webhook -n keti
   ```

5. **MWC에 PVC 추가** (`caBundle` 유지하려면 patch 권장):

   ```bash
   kubectl patch mutatingwebhookconfiguration ai-storage-webhook --type='json' \
     -p='[{"op": "replace", "path": "/webhooks/0/rules/0/resources", "value": ["pods", "persistentvolumeclaims"]}]'
   ```

6. **테스트 네임스페이스/PVC 재생성**

   ```bash
   kubectl delete namespace gpu-webhook-test --ignore-not-found
   kubectl apply -f test-gpu-workload.yaml
   ```

---

## 로컬에서 로직 검증 (클러스터와 무관)

레포 코드 기준 PVC mutation 단위 테스트는 통과합니다.

```bash
cd ai-storage-webhook
go test ./pkg/webhook/ -run 'TestPVC_' -v
```

예시 출력 요약:

- `TestPVC_TrainGPU_Workload` → `storage-performance` 패치 기대  
- `TestPVC_HandleRequest_MutatesStorageClass` → Admission 핸들러 경로까지 검증  

---

## 요약: “동작을 클러스터에서 보려면”

| 조건 | 없으면 생기는 현상 |
|------|-------------------|
| MWC에 `persistentvolumeclaims` | 웹훅이 PVC에 안 붙음 → default SC만 적용 |
| 웹훅 이미지 = PVC 지원 빌드 | PVC 생성 시 InternalError (`/spec/containers/-`) |
| 노드에 새 이미지 실제 반영 (`Never` 정책) | 빌드만 하고 배포 안 됨 → 계속 구버전 |
| `storage-performance` 등 SC 존재 | 주입 후 바인딩/프로비저닝 실패 가능 |

현재 이 문서 작성 시점 기준, **클러스터에서는 MWC를 PVC 포함으로 두면 구버전 이미지 때문에 PVC 생성이 깨지므로, MWC는 다시 `pods`만으로 되돌려 둔 상태**에서 문서를 마무리했습니다.  
**최신 이미지를 노드에 올린 뒤** 다시 `persistentvolumeclaims`를 켜면 end-to-end로 확인할 수 있습니다.

---

## ✅ 요청하신 순서대로 진행한 결과 (2026-03-20 재실행)

아래 순서를 **그대로** 수행했습니다.

1. 웹훅 최신 코드로 이미지 빌드 (`docker build -t ketidevit2/ai-storage-webhook:latest`)  
2. **ai-storage-master** 노드의 containerd(`k8s.io`)에 `docker save | ctr images import`  
3. `kubectl rollout restart deployment/ai-storage-webhook -n keti`  
4. MWC rules에 `persistentvolumeclaims` 포함 (`kubectl patch mutatingwebhookconfiguration …`)  
5. `kubectl delete namespace gpu-webhook-test` 후 `kubectl apply -f test-gpu-workload.yaml` 로 PVC 재생성  

추가로, **클러스터 Default SC(`nfs-client`)가 웹훅보다 먼저 붙는 경우**를 대비해 코드에 다음을 반영했습니다.

- `AI_STORAGE_REPLACEABLE_STORAGE_CLASSES` (기본값 `nfs-client`): 이 이름의 SC는 “사용자 명시”가 아니라 **티어 정책 SC로 `replace` 가능**  
- Deployment 매니페스트에 env 예시 추가 + 실제 클러스터에 `kubectl set env … AI_STORAGE_REPLACEABLE_STORAGE_CLASSES=nfs-client` 적용  

### 🎯 최종 관측 (TLS 문제로 웹훅 미적용)

PVC는 생성되었으나 **웹훅 변형이 적용되지 않았습니다.**

| 항목 | 실제 출력 |
|------|-----------|
| `spec.storageClassName` | `nfs-client` |
| `metadata.annotations["ai-storage/selected-tier"]` | *(없음)* |

**원인:** 웹훅 Pod 로그에 아래와 같이 **TLS 핸드셰이크 실패**가 반복됩니다.

```text
http: TLS handshake error from ... remote error: tls: bad certificate
```

`MutatingWebhookConfiguration`의 `failurePolicy`가 `Ignore`이므로, API 서버는 웹훅 호출에 실패해도 **PVC/Pod 생성은 그대로 진행**하고, 그 결과 **DefaultStorageClass만 적용**된 상태(`nfs-client`)로 남습니다.

### 🔧 TLS를 맞춘 뒤 기대하는 정상 출력

`caBundle`(MWC)과 웹훅 서버가 쓰는 `tls.crt`가 **같은 CA로 검증 가능**해야 합니다. (예: `ai-storage-webhook/scripts/generate-certs.sh` 등으로 재발급 후 MWC `caBundle` 갱신)

정상이라면 `test-gpu-workload`의 PVC(`stage=train`, `gpuCount=1`)에 대해:

| 항목 | 기대 출력 |
|------|-----------|
| `spec.storageClassName` | `storage-performance` |
| `metadata.annotations["ai-storage/selected-tier"]` | `performance` |
| `metadata.labels["ai-storage-selected-tier"]` | `performance` |

확인 명령:

```bash
kubectl get pvc -n gpu-webhook-test gpu-test-data -o jsonpath='{.spec.storageClassName}{"\n"}'
kubectl get pvc -n gpu-webhook-test gpu-test-data -o jsonpath='{.metadata.annotations.ai-storage\/selected-tier}{"\n"}'
kubectl logs -n keti -l app=ai-storage-webhook --tail=50
```
