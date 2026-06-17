# CSD / 물리 tier 분리 주의사항

## 현재 검증 범위

본 패키지의 CIFAR-10 및 추가 전처리 워크로드 검증은 다음 항목까지만 보장한다.

- PVC annotation (`storage.keti.io/workload-type`, `data-role`, `priority`, `io-pattern`, `latency`, `access-pattern`) 기반 webhook 의 **논리 tier 선정 로직** (L1 / L2 / L3 / S3 결정)
- Mutating webhook 이 PVC `spec.storageClassName` 을 `storage-l1` / `storage-l2` / `storage-l3` / `storage-s3` 중 하나로 자동 주입하는 동작
- Pod 에 `schedulerName=ai-storage-scheduler` 및 `insight-trace` sidecar 가 주입되는 동작
- 위 흐름이 동일 클러스터 안에서 end-to-end 로 성공하는지 여부

## 물리 backend 분리는 검증되지 않았다

검증 클러스터의 `storage-l1`, `storage-l2`, `storage-l3`, `storage-s3` 네 StorageClass 는 모두 동일한 provisioner 인 `cluster.local/nfs-subdir-external-provisioner` 를 사용한다. 즉,

- 어느 tier 의 PVC 도 결국 같은 NFS export 로 prov 된다.
- IOPS / latency / bandwidth 측면의 실제 tier 분리는 본 패키지가 보장하지 않는다.
- 따라서 "L1 PVC 가 ultra-low latency 로 동작했다" 같은 성능 주장을 검증하려면 별도 backend 분리가 필요하다.

## 다른 기관 서버에서 권장하는 매핑

기관별 storage 자산에 따라 다음 중 하나를 선택하여 `manifests/01-storageclass/storageclass-l1-l2-l3-s3.yaml` 의 `provisioner` 와 `parameters` 를 교체한다.

| 논리 tier | 권장 backend 예시 | 권장 provisioner |
|---|---|---|
| `storage-l1` | NVMe-SSD 로컬 PV, NVMe-CSI | 로컬 CSI (e.g. `csi.openebs.io`, `local-path`) |
| `storage-l2` | NVMe-SSD 공유 (NFS over RDMA, Lustre) | NVMe NFS provisioner / Lustre CSI |
| `storage-l3` | HDD 기반 capacity NFS | 기관 NFS provisioner |
| `storage-s3` | Object storage (Ceph RGW, MinIO) 또는 별도 archive bucket | `csi-s3`, `objectstorage.k8s.io` 류 |

매핑 변경 후 다음 두 가지를 함께 검토한다.

1. `parameters` 의 `dataClass`, `tier`, `tierRole` 라벨이 새 backend 의 의미와 맞도록 다듬는다.
2. `reclaimPolicy` / `volumeBindingMode` 는 기관별 운영 정책과 일치하는지 확인한다 (현재 `Retain` + `WaitForFirstConsumer`).

## CSD 노드 직접 점검 미완료

10.0.4.250 CSD 노드 직접 확인은 본 검증 사이클에서 SSH 인증 문제로 완료하지 못했다. 따라서

- CSD 디바이스가 노출하는 raw 성능 (예: 컴퓨테이션 오프로드, FPGA accel) 은 본 패키지로 검증되지 않았다.
- CSD 를 storage tier 에 매핑하려면 별도 CSI 또는 device plugin 으로 노출한 뒤 `storage-l1` 또는 `storage-l2` 의 provisioner 로 연결해야 한다.
- 기관 서버에서 CSD 를 사용한다면 다음 항목을 후속 검증으로 진행할 것을 권장한다.
  - CSD 디바이스 mount → CSI provisioner 등록 → StorageClass `provisioner` 필드 교체
  - IOPS / latency 비교 (`fio` 등) 로 L1 ↔ L3 차이를 측정
  - Pod migration 시 CSD 노드 ↔ non-CSD 노드 간 데이터 이동 비용 측정

## 정리

- 본 패키지가 보장하는 것: webhook 의 tier 결정 로직과 PVC `storageClassName` 자동 주입.
- 본 패키지가 보장하지 않는 것: 실제 물리 tier 성능 분리, CSD 가속 효과, IOPS / latency 수치.
- 운영 환경 적용 전에 backend 매핑과 성능 측정을 반드시 별도로 수행한다.
