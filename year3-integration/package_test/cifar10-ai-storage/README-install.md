# CIFAR-10 AI Storage 패키지 설치 초안

## 목적

이 패키지는 AI Storage webhook, scheduler, orchestrator, `insight-trace` sidecar, L1/L2/L3/S3 논리 StorageClass, CIFAR-10 예제 workload를 다른 기관 서버에 설치하기 위한 초안이다.

## 포함 파일

- `year3-integration/package/cifar10-ai-storage/setup.sh`
- `year3-integration/package/cifar10-ai-storage/manifests/storageclass-l1-l2-l3-s3.yaml`
- `year3-integration/package/cifar10-ai-storage/images/image-list.txt`
- `ai-storage-webhook/deployments/webhook-deployment.yaml`
- `ai-storage-webhook/deployments/webhook-config.yaml`
- `ai-storage-webhook/scripts/generate-certs.sh`
- `ai-storage-scheduler/deployments/ai-storage-scheduler.yaml`
- `ai-storage-orchestrator/deployments/cluster-orchestrator.yaml`
- `year3-integration/4.integration_test/manifests/cifar10-preprocessing-workload.yaml`
- `year3-integration/4.integration_test/manifests/cifar10-training-workload.yaml`
- `year3-integration/4.integration_test/manifests/cifar10-inference-workload.yaml`
- `year3-integration/4.integration_test/manifests/checkpoint-io-workload.yaml`
- `year3-integration/4.integration_test/README-cifar10-workloads.md`

## 이미지 tar 후보

`images/image-list.txt` 기준으로 사전 pull/save 또는 폐쇄망 import를 준비한다.

```bash
docker pull ketidevit2/ai-storage-webhook:latest
docker pull ketidevit2/insight-trace:job-exit-20260527
docker pull ketidevit2/keti-ai-storage-scheduler:latest
docker pull pytorch/pytorch:2.3.1-cuda12.1-cudnn8-runtime
docker pull registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
docker save ketidevit2/ai-storage-webhook:latest -o images/ai-storage-webhook_latest.tar
docker save ketidevit2/insight-trace:job-exit-20260527 -o images/insight-trace_job-exit-20260527.tar
docker save ketidevit2/keti-ai-storage-scheduler:latest -o images/keti-ai-storage-scheduler_latest.tar
docker save pytorch/pytorch:2.3.1-cuda12.1-cudnn8-runtime -o images/pytorch_2.3.1-cuda12.1.tar
docker save registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2 -o images/nfs-subdir-external-provisioner_v4.0.2.tar
```

`ai-storage-orchestrator:latest`는 현재 manifest가 로컬 이미지(`imagePullPolicy: Never`)를 사용하므로 대상 노드의 container runtime에 별도 import가 필요하다.

## 설치 순서

1. 대상 클러스터에 Kubernetes, GPU device plugin, NFS provisioner 또는 기관별 CSI를 준비한다.
2. 폐쇄망이면 `images/*.tar`를 각 실행 노드에 import한다.
3. `TARGET_NAMESPACE=ai-storage-workloads ./year3-integration/package/cifar10-ai-storage/setup.sh`를 실행한다.
4. CIFAR-10 예제까지 함께 배포하려면 `APPLY_CIFAR_EXAMPLES=true`를 추가한다.
5. 설치 후 namespace label을 확인한다.

```bash
kubectl get namespace ai-storage-workloads --show-labels
kubectl get storageclass storage-l1 storage-l2 storage-l3 storage-s3
kubectl get deploy -n keti ai-storage-webhook ai-storage-scheduler
kubectl get deploy -n kube-system ai-storage-orchestrator
```

## 검증 순서

```bash
kubectl apply -f year3-integration/4.integration_test/manifests/cifar10-preprocessing-workload.yaml
kubectl get pvc -n ai-storage-workloads
kubectl get pod -n ai-storage-workloads -o wide
kubectl logs job/cifar10-preprocessing-workload -n ai-storage-workloads -c preprocess
kubectl logs job/cifar10-preprocessing-workload -n ai-storage-workloads -c insight-trace
kubectl get job -n ai-storage-workloads
```

## 물리 tier 분리 주의

현재 검증 클러스터의 `storage-l1`, `storage-l2`, `storage-l3`, `storage-s3`는 모두 `cluster.local/nfs-subdir-external-provisioner`를 사용했다. 따라서 webhook의 논리 tier 선택과 annotation/storageClassName 주입은 검증됐지만, 실제 L1/L2/L3/S3 물리 backend 분리는 별도 provisioner, CSI, NFS export, 또는 storage backend 매핑이 필요하다.
