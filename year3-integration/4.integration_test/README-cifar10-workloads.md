# CIFAR-10 실제 데이터 워크로드 검증

## 1. 생성 파일 목록

### YAML

- `year3-integration/4.integration_test/manifests/cifar10-preprocessing-workload.yaml`
- `year3-integration/4.integration_test/manifests/cifar10-training-workload.yaml`
- `year3-integration/4.integration_test/manifests/cifar10-inference-workload.yaml`
- `year3-integration/4.integration_test/manifests/checkpoint-io-workload.yaml`

### Python

- `year3-integration/4.integration_test/scripts/workloads/cifar10_preprocess.py`
- `year3-integration/4.integration_test/scripts/workloads/cifar10_train.py`
- `year3-integration/4.integration_test/scripts/workloads/cifar10_inference.py`
- `year3-integration/4.integration_test/scripts/workloads/checkpoint_io.py`

## 2. 워크로드별 역할 요약

- `cifar10-preprocessing-workload`: `torchvision.datasets.CIFAR10`으로 CIFAR-10을 다운로드하거나 `/data/raw`의 기존 데이터를 사용하고, resize/normalize/tensor 변환 결과를 `/data/preprocessed/train.pt`, `/data/preprocessed/test.pt`로 저장한다.
- `cifar10-training-workload`: 전처리된 `train.pt`를 읽어 작은 CNN을 1~2 epoch 학습하고 `/data/checkpoints/cifar10_model.pt`와 `/data/logs/train_summary.json`을 저장한다.
- `cifar10-inference-workload`: `/data/checkpoints/cifar10_model.pt`를 로드해 test tensor를 추론하고 `/data/results/inference_results.json`, `/data/logs/inference_summary.json`을 저장한다.
- `checkpoint-io-workload`: PyTorch tensor checkpoint를 반복 저장/로드하여 checkpoint PVC의 read/write 부하와 summary를 기록한다.

## 3. PVC별 annotation과 기대 tier

| PVC | 주요 annotation | 기대 tier | 기대 storageClass |
| --- | --- | --- | --- |
| `cifar10-raw-dataset-pvc` | `workload-type=dataset-ingest`, `data-role=raw-dataset`, `priority=medium`, `io-pattern=large-read` | `L3` | `storage-l3` |
| `cifar10-preprocessing-pvc` | `workload-type=preprocessing`, `data-role=preprocessing-input`, `priority=high`, `io-pattern=large-read`, `latency=low` | `L2` | `storage-l2` |
| `cifar10-cache-pvc` | `workload-type=preprocessing`, `data-role=cache`, `access-pattern=repeated`, `latency=ultra-low` | `L1` | `storage-l1` |
| `cifar10-checkpoint-pvc` | `workload-type=training`, `data-role=intermediate`, `priority=medium`, `io-pattern=large-write` | `L3` | `storage-l3` |
| `cifar10-result-log-pvc` | `workload-type=archive`, `data-role=result-backup`, `priority=low` | `S3` | `storage-s3` |

`storageClassName`은 YAML에 직접 명시하지 않는다. namespace label `keti-ai-storage-injection=enabled`가 있는 상태에서 webhook이 `ai-storage/selected-tier`, `ai-storage/selected-storage-class`, `ai-storage/tier-reason`, `spec.storageClassName`을 주입해야 한다.
Job Pod에는 `insight-trace` sidecar가 주입된다. sidecar가 메인 컨테이너 종료를 감지할 수 있도록 `cifar10-workload` ServiceAccount와 Pod 조회 Role/RoleBinding을 함께 생성한다.

```bash
kubectl label namespace ai-storage-workloads keti-ai-storage-injection=enabled --overwrite
```

Fallback이 꼭 필요할 때만 아래 방식처럼 직접 지정한다. 기본 검증에서는 사용하지 않는다.

```yaml
# spec:
#   storageClassName: storage-l2
```

## 4. YAML 경로

```bash
year3-integration/4.integration_test/manifests/cifar10-preprocessing-workload.yaml
year3-integration/4.integration_test/manifests/cifar10-training-workload.yaml
year3-integration/4.integration_test/manifests/cifar10-inference-workload.yaml
year3-integration/4.integration_test/manifests/checkpoint-io-workload.yaml
```

## 5. Python 스크립트 경로

```bash
year3-integration/4.integration_test/scripts/workloads/cifar10_preprocess.py
year3-integration/4.integration_test/scripts/workloads/cifar10_train.py
year3-integration/4.integration_test/scripts/workloads/cifar10_inference.py
year3-integration/4.integration_test/scripts/workloads/checkpoint_io.py
```

YAML은 단독 실행을 위해 동일 실행 로직을 `ConfigMap`으로 포함한다. 위 Python 파일은 로컬 검토와 이후 커스텀 이미지 bake-in용 원본 스크립트로 사용한다.

## 6. 실행 순서

1. namespace label 확인
2. `cifar10-preprocessing-workload` 실행
3. PVC `selected-tier`와 `storageClassName` 확인
4. preprocessing 결과 파일 확인
5. `cifar10-training-workload` 실행
6. GPU node 배치 확인
7. checkpoint 생성 확인
8. `cifar10-inference-workload` 실행
9. inference 결과 확인
10. `checkpoint-io-workload` 실행
11. checkpoint I/O summary 확인

## 7. 검증 명령

아래 `delete` 명령은 각 YAML별 정리 명령이다. preprocessing 결과, checkpoint, inference 결과를 이어서 검증해야 하므로 전체 순서가 끝난 뒤 실행한다.

### 이미지 사전 준비

폐쇄망이거나 image pull이 불안정하면 각 worker에 이미지를 미리 pull/import한다.

```bash
docker pull pytorch/pytorch:2.3.1-cuda12.1-cudnn8-runtime
docker save pytorch/pytorch:2.3.1-cuda12.1-cudnn8-runtime -o pytorch-2.3.1-cuda12.1.tar

# 각 worker node에서 container runtime에 맞게 import한다.
# ctr -n k8s.io images import pytorch-2.3.1-cuda12.1.tar
# crictl images | grep pytorch
```

### 1단계: namespace label

```bash
kubectl get namespace ai-storage-workloads --show-labels
kubectl label namespace ai-storage-workloads keti-ai-storage-injection=enabled --overwrite
```

### 2단계: preprocessing

```bash
kubectl apply -f year3-integration/4.integration_test/manifests/cifar10-preprocessing-workload.yaml
kubectl get pvc -n ai-storage-workloads
kubectl describe pvc cifar10-raw-dataset-pvc -n ai-storage-workloads
kubectl describe pvc cifar10-preprocessing-pvc -n ai-storage-workloads
kubectl describe pvc cifar10-cache-pvc -n ai-storage-workloads
kubectl describe pvc cifar10-result-log-pvc -n ai-storage-workloads
kubectl get pod -n ai-storage-workloads -o wide
kubectl logs job/cifar10-preprocessing-workload -n ai-storage-workloads -c preprocess
kubectl logs job/cifar10-preprocessing-workload -n ai-storage-workloads -c insight-trace
```

전처리 결과 파일 확인:

```bash
kubectl logs job/cifar10-preprocessing-workload -n ai-storage-workloads -c preprocess | grep -E 'train.pt|test.pt|preprocess_summary.json|completed'
```

삭제:

```bash
kubectl delete -f year3-integration/4.integration_test/manifests/cifar10-preprocessing-workload.yaml
```

### 3단계: training

```bash
kubectl apply -f year3-integration/4.integration_test/manifests/cifar10-training-workload.yaml
kubectl get pvc -n ai-storage-workloads
kubectl describe pvc cifar10-preprocessing-pvc -n ai-storage-workloads
kubectl describe pvc cifar10-checkpoint-pvc -n ai-storage-workloads
kubectl describe pvc cifar10-result-log-pvc -n ai-storage-workloads
kubectl get pod -n ai-storage-workloads -o wide
kubectl logs job/cifar10-training-workload -n ai-storage-workloads -c training
kubectl logs job/cifar10-training-workload -n ai-storage-workloads -c insight-trace
```

GPU node와 checkpoint 확인:

```bash
kubectl get pod -n ai-storage-workloads -l job-name=cifar10-training-workload -o wide
kubectl logs job/cifar10-training-workload -n ai-storage-workloads -c training | grep -E 'cifar10_model.pt|train_summary.json|completed'
```

삭제:

```bash
kubectl delete -f year3-integration/4.integration_test/manifests/cifar10-training-workload.yaml
```

### 4단계: inference

```bash
kubectl apply -f year3-integration/4.integration_test/manifests/cifar10-inference-workload.yaml
kubectl get pvc -n ai-storage-workloads
kubectl describe pvc cifar10-preprocessing-pvc -n ai-storage-workloads
kubectl describe pvc cifar10-checkpoint-pvc -n ai-storage-workloads
kubectl describe pvc cifar10-result-log-pvc -n ai-storage-workloads
kubectl get pod -n ai-storage-workloads -o wide
kubectl logs job/cifar10-inference-workload -n ai-storage-workloads -c inference
kubectl logs job/cifar10-inference-workload -n ai-storage-workloads -c insight-trace
```

추론 결과 확인:

```bash
kubectl logs job/cifar10-inference-workload -n ai-storage-workloads -c inference | grep -E 'inference_results.json|inference_summary.json|completed'
```

삭제:

```bash
kubectl delete -f year3-integration/4.integration_test/manifests/cifar10-inference-workload.yaml
```

### 5단계: checkpoint I/O

```bash
kubectl apply -f year3-integration/4.integration_test/manifests/checkpoint-io-workload.yaml
kubectl get pvc -n ai-storage-workloads
kubectl describe pvc cifar10-checkpoint-pvc -n ai-storage-workloads
kubectl describe pvc cifar10-result-log-pvc -n ai-storage-workloads
kubectl get pod -n ai-storage-workloads -o wide
kubectl logs job/checkpoint-io-workload -n ai-storage-workloads -c checkpoint-io
kubectl logs job/checkpoint-io-workload -n ai-storage-workloads -c insight-trace
```

I/O 결과 확인:

```bash
kubectl logs job/checkpoint-io-workload -n ai-storage-workloads -c checkpoint-io | grep -E 'io_test_|checkpoint_io_summary.json|completed'
```

삭제:

```bash
kubectl delete -f year3-integration/4.integration_test/manifests/checkpoint-io-workload.yaml
```

## 8. 실패 시 확인 항목

- PVC가 `Bound` 상태인지 확인한다.
- PVC annotation에 `ai-storage/selected-tier`가 존재하는지 확인한다.
- PVC annotation에 `ai-storage/selected-storage-class`가 존재하는지 확인한다.
- PVC annotation에 `ai-storage/tier-reason`이 존재하는지 확인한다.
- `spec.storageClassName`이 `storage-l1`, `storage-l2`, `storage-l3`, `storage-s3` 중 하나인지 확인한다.
- training/inference Pod가 `gpu-server-03`에 스케줄링되었는지 확인한다.
- `nvidia.com/gpu: 1` 요청 때문에 Pod가 Pending이면 `kubectl describe pod`로 GPU allocatable과 taint/toleration을 확인한다.
- CIFAR-10 다운로드 실패 시 폐쇄망 여부를 확인하고 `/data/raw`에 CIFAR-10 원본을 미리 준비한 뒤 `CIFAR10_DOWNLOAD=false`로 바꾼다.
- 이미지 pull 실패 시 `pytorch/pytorch:2.3.1-cuda12.1-cudnn8-runtime` 이미지를 worker에 사전 import한다.
- inference가 checkpoint 오류로 실패하면 training 완료 후 `/data/checkpoints/cifar10_model.pt`가 생성되었는지 확인한다.
- `result/log` PVC가 S3 tier로 바인딩될 때 mount 동작이 느리거나 실패하면 provisioner event와 PVC event를 함께 확인한다.

## 9. MSCOCO 확장 계획

다음 단계에서만 확장한다.

- `mscoco-preprocessing-workload`: COCO image와 annotation을 분리 PVC에 적재하고 resize, normalize, annotation index 생성을 수행한다.
- `mscoco-multimodal-workload`: image-caption 또는 detection-style multimodal 학습/추론 workload로 GPU와 large-read/cache/checkpoint tier 정책을 함께 검증한다.
