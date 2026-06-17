# AI Storage 오케스트레이션 진단 & 수정 참고

> **목적:** 라이브 클러스터에서 관측된 오케스트레이션 동작 이상을 정리하고, 소스 수정 담당자가
> 어디를 고쳐야 하는지 / 어떻게 검증하는지를 한 문서로 전달한다.
>
> **진단 일시:** 2026-06-16 17:29 KST
> **진단 환경:** cpu-master-server(v1.34.3, control-plane) / csd-server-01(v1.29.15) / gpu-server-03(v1.32.9)
> **진단 방식:** 라이브 클러스터 read-only 조회(kubectl) + 패키지 소스 grep. **코드/클러스터 변경은 하지 않음.**

---

## TL;DR

컴포넌트는 전부 Running 이고 forecaster→policy-engine→orchestrator 호출 체인도 흐른다.
그러나 **파이프라인이 end-to-end로 완주하지 못한다.** 핵심 원인 2개 + 부수 문제 3개.

| ID | 심각도 | 증상 | 근본 원인(추정) | 수정 위치 |
|----|--------|------|------------------|-----------|
| **ISSUE-1** | 🔴 High | 존재하지 않는 StorageClass `high-throughput` 으로 PVC 생성 → 1분마다 `ProvisioningFailed` 무한 반복 | orchestrator 바이너리에 SC 이름 **하드코딩** (ConfigMap/차트/매니페스트 어디에도 없음) | orchestrator Go 소스 (provisioning 로직) |
| **ISSUE-2** | 🔴 High | `OrchestrationPolicy` CR이 **5,288개** 누적, 거의 전부 `action=delay (below approval threshold)` → 아무 액션도 실행 안 됨 | policy-engine의 승인 임계값이 forecaster 출력 대비 과도하게 높거나, 승인된 정책의 정리(GC) 로직 부재 | policy-engine Go 소스 (승인 임계값 + CR GC) |
| **ISSUE-3** | 🟠 Med | 파이프라인이 `pause-after-preprocessing` 게이트에서 3시간+ 정지 | ISSUE-2로 인해 게이트 해제 조건(정책 승인)이 충족되지 않음. resume 스크립트는 존재함 | 운영 절차 / ISSUE-2 의존 |
| **ISSUE-4** | 🟡 Low | 노드 버전 스큐 v1.34 / v1.32 / v1.29 + OS 18.04~24.04 혼재 | 워커 노드 미업그레이드 | 운영(노드 재구성) |
| **ISSUE-5** | 🟡 Low | 누적된 정책 CR 5천+ 가 etcd/컨트롤러 부하 | ISSUE-2의 결과물 | 즉시 정리 가능 |

> **소스 위치 힌트:** `docs/source-inventory.md` 기준 매니페스트 원본은
> `year3-integration/package_test/ai-storage-integration-package/` 에 있다.
> orchestrator/policy-engine **Go 소스 레포는 이 패키지에 포함돼 있지 않으므로**(여기엔 `images/*.tar` 빌드 산출물만 존재),
> 해당 소스 레포에서 아래 키워드로 수정 지점을 찾을 것.

---

## ISSUE-1 — 존재하지 않는 StorageClass `high-throughput`

### 관측된 증거
```
# orchestrator 로그 (kube-system/ai-storage-orchestrator)
Provisioning provisioning-63a00aae: Created for workload argo/workflow-controller
  with size 100Gi, class high-throughput
Provisioning ...: Creating PVC pvc-workflow-controller-provisio
  (size=100Gi, class=high-throughput, access=ReadWriteOnce) in namespace argo

# argo 네임스페이스 이벤트 (1분 간격으로 8일째 반복)
Warning  ProvisioningFailed  persistentvolumeclaim/pvc-workflow-controller-provisio
  storageclass.storage.k8s.io "high-throughput" not found
```

### 실제 클러스터에 존재하는 StorageClass
```
storage-l1   cluster.local/nfs-subdir-external-provisioner   (tier=L1, cache-burst)
storage-l2   cluster.local/nfs-subdir-external-provisioner   (tier=L2, nvme-hot) [default]
storage-l3   cluster.local/nfs-subdir-external-provisioner   (tier=L3, hdd-capacity)
storage-s3   cluster.local/nfs-subdir-external-provisioner
```
→ `high-throughput` 라는 이름의 StorageClass는 **존재하지 않는다.** 패키지의
`ai-storage-installer/manifests/storageclasses/ai-storage-tier-storageclasses.yaml` 는
`storage-l1/l2/l3/s3` 만 정의한다.

### 원인 (확인된 사실)
- orchestrator ConfigMap(`kube-system/ai-storage-orchestrator-config`)에는 **storageClass 매핑이 전혀 없다.**
  (migration timeout, checkpoint_pv_size, metrics target 만 존재)
- 패키지 전체 grep 결과 `high-throughput` 은 **로그 파일에만** 나오고 소스/차트/매니페스트에는 없다.
- 따라서 `high-throughput` 문자열은 **orchestrator 바이너리 내부에 하드코딩**돼 있다고 판단됨.

### 수정 방향 (소스 레포에서)
1. orchestrator Go 소스에서 `"high-throughput"` 문자열 상수를 검색:
   ```bash
   grep -rn "high-throughput" <orchestrator-repo>/
   ```
2. 두 가지 중 택1:
   - **(권장) 설정화:** 하드코딩을 제거하고 ConfigMap `config.yaml` 에서 읽도록 변경.
     예) `provisioning.default_storage_class: storage-l2`, 또는 tier→SC 매핑 테이블.
   - **(임시) 상수 교체:** `high-throughput` → 실제 존재하는 `storage-l2`(default, nvme-hot)로 치환.
3. 재빌드 → `images/ai-storage-orchestrator_*.tar` 재패키징 → 재배포.

### ⚡ 코드 수정 없이 즉시 멈추는 우회책 (운영 핫픽스)
`high-throughput` 라는 **이름의 StorageClass를 별칭(alias)으로 생성**하면 PVC 무한 실패가 즉시 멈춘다.
근본 해결은 아니지만 클러스터 부하/로그 노이즈를 바로 제거한다.
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: high-throughput
provisioner: cluster.local/nfs-subdir-external-provisioner   # storage-l2와 동일 provisioner
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```
> 단, orchestrator가 의도한 "high-throughput" 성능 특성과 nfs provisioner의 실제 성능은 다르므로,
> 의미적으로 맞는 tier(storage-l2 nvme-hot)에 매핑하는 것이 맞는지 설계 의도를 확인할 것.

---

## ISSUE-2 — OrchestrationPolicy CR 폭증 + 전부 `delay`

### 관측된 증거
```
# CR 개수 (진단 시점)
$ kubectl get orchestrationpolicy -n apollo --no-headers | wc -l
5288        # 계속 증가 중

# policy-engine 로그 (apollo/orchestration-policy-engine) — 대부분 이 패턴 반복
Reconciling OrchestrationPolicy ... policyType=scaling urgency=HIGH probability=44 priorityScore=84
AUTO-APPROVING POLICY ...
Policy Agent decision: action=delay
  reason=policy remains below forecaster-aligned approval threshold
```

### 문제 해석
- `urgency=HIGH`, `priorityScore=84` 인 정책조차 `action=delay` 로 빠진다.
- 사유가 항상 `below forecaster-aligned approval threshold` → **승인 임계값이 forecaster 출력 대비 너무 높아
  어떤 정책도 실행 단계로 넘어가지 못한다.** (또는 forecaster가 임계값을 못 넘기는 낮은 값을 계속 내보냄)
- 동시에 처리/거절된 CR이 정리되지 않아 **무한 누적**된다 (GC 부재).

### 수정 방향 (소스 레포에서)
1. policy-engine Go 소스에서 임계값 비교 로직 검색:
   ```bash
   grep -rni "approval threshold\|forecaster-aligned\|action.*delay\|approvalThreshold" <policy-engine-repo>/
   ```
2. 점검 포인트:
   - 임계값이 상수 하드코딩인가, 설정/CR spec(`spec.parameters.threshold`)에서 오는가?
     (셸 스크립트 `scripts/orchestration-module/17-...sh:317` 이 `spec.parameters.threshold` 를 읽는 것으로 보아 CR에 threshold 필드가 있음 — 이 값이 어떻게 채워지는지 추적)
   - forecaster가 내보내는 predicted 값과 임계값의 단위/스케일이 일치하는가? (예: % vs 0~1)
   - `urgency=HIGH & priorityScore=84` 가 왜 임계값을 못 넘는지 — 비교 대상이 잘못된 필드일 가능성.
3. **CR GC:** 승인/거절 종료된 OrchestrationPolicy를 정리하는 로직(TTL 또는 reconcile 후 delete/own-reference) 추가.
   안 그러면 고쳐도 누적은 계속됨.

### forecaster 연계 확인
- `node-resource-forecaster`(apollo)는 1/1 Running. 임계값 정상화 전에 forecaster 출력값을 먼저 확인:
  ```bash
  kubectl logs -n apollo deploy/node-resource-forecaster --tail=50
  ```
  예측값이 비정상(항상 낮음/0)이면 ISSUE-2의 진짜 원인이 forecaster 쪽일 수 있다.

---

## ISSUE-3 — 파이프라인 pause 게이트 미해제

### 관측된 증거
```
# 워크플로 ai-storage-workloads/ai-storage-main-pipeline-run-20260616-135621 (3h25m+ Running)
phase   node
Succeeded  preprocessing
Succeeded  pause-before-preprocessing
Running    pause-after-preprocessing   <-- 여기서 정지
Running    [2]
```
- `pause-after-preprocessing` 가 풀리지 않아 학습 단계로 진행 못 함.

### 원인
- pause/resume 게이트 메커니즘은 **셸 스크립트로 구현돼 있고 소스가 패키지에 있음**:
  - `scripts/step-pause-keti-orchestration.sh`
    - `pause` 모드: workflow suspend=true, ArgoCD auto-sync off, kueue ClusterQueue `stopPolicy=Hold`,
      관련 deployment replicas=0
    - `release/resume` 모드: `set_workflow_suspend false`, `scale_deployment_gate release ...`,
      `release_argocd_sync_gate` (라인 82~86, 186~202)
- 즉 resume 로직 자체는 존재한다. 게이트가 안 풀리는 이유는 **resume 트리거 조건이 정책 승인(ISSUE-2)에
  묶여 있기 때문**으로 보인다. ISSUE-2를 고치면 자연 해소될 가능성이 높다.

### 수정/운영 방향
1. 우선 ISSUE-2 해결 후 게이트가 자동 해제되는지 관찰.
2. 즉시 수동 해제가 필요하면:
   ```bash
   # 워크플로 suspend 해제 (Argo)
   kubectl patch wf -n ai-storage-workloads ai-storage-main-pipeline-run-20260616-135621 \
     --type merge -p '{"spec":{"suspend":false}}'
   # 또는 패키지 스크립트의 release 경로 사용
   bash scripts/step-pause-keti-orchestration.sh release   # (실제 서브커맨드는 스크립트 확인)
   ```
   > 단, 수동 해제는 정책 승인 게이트의 의도를 우회하는 것이므로 데모/디버깅 한정으로 사용.

---

## ISSUE-4 — 노드 버전 스큐 (운영 위험)

| 노드 | 역할 | kubelet | OS |
|------|------|---------|-----|
| cpu-master-server | control-plane | v1.34.3 | Ubuntu 24.04 |
| gpu-server-03 | worker | v1.32.9 | Ubuntu 22.04 |
| csd-server-01 | worker | v1.29.15 | Ubuntu 18.04 |

- control-plane(1.34) ↔ worker(1.29)는 **마이너 5단계 차이로 kubeadm version-skew 정책(±3) 위반.**
- 당장 안 터져도 API 비호환/스케줄 이상 위험. 운영 클러스터 기준 부적격 구성.
- **조치:** 워커 노드 kubelet을 control-plane 기준 ±3 이내로 업그레이드 (1.29→최소 1.31+). OS도 정비 권장.
- 본 문서의 ISSUE-1~3과는 독립적인 인프라 작업.

---

## ISSUE-5 — 누적 CR 즉시 정리 (핫픽스)

ISSUE-2를 고치기 전이라도, 누적된 종료 정책 CR은 부하이므로 정리 가능.
```bash
# 개수 확인
kubectl get orchestrationpolicy -n apollo --no-headers | wc -l

# (주의) 전체 삭제 — 진행 중 정책까지 지우므로, 가능하면 상태/라벨로 필터링할 것.
# kubectl delete orchestrationpolicy -n apollo --all
```
> 근본적으로는 ISSUE-2의 GC 로직으로 해결해야 하며, 수동 삭제는 임시방편.

---

## 권장 수정 순서

1. **ISSUE-5 + ISSUE-1 우회책** (운영, ~10분): CR 정리 + `high-throughput` SC alias 생성 → 클러스터 부하/노이즈 즉시 제거.
2. **ISSUE-2** (소스, 0.5~2일): 승인 임계값 정상화 + CR GC. → 오케스트레이션이 실제 액션을 실행하게 됨.
3. **ISSUE-3** (의존): ISSUE-2 해결 후 게이트 자동 해제 확인. 안 되면 resume 트리거 점검.
4. **ISSUE-1 근본수정** (소스, 0.5~1일): orchestrator의 SC 하드코딩 제거/설정화.
5. **ISSUE-4** (운영, 1~3일): 노드 버전 정비.

---

## 검증 절차 (수정 후 이걸로 "동작함"을 확인)

```bash
# 1) PVC 무한 실패가 멈췄는가
kubectl get events -A --field-selector type=Warning | grep ProvisioningFailed   # 비어야 정상

# 2) 정책 CR이 더 이상 무한 증가하지 않고, delay 외 action이 나오는가
kubectl get orchestrationpolicy -n apollo --no-headers | wc -l                   # 수렴해야 함
kubectl logs -n apollo deploy/orchestration-policy-engine --tail=50 | grep "action="

# 3) 파이프라인이 preprocessing 다음 단계로 진행하는가
kubectl get wf -n ai-storage-workloads
#  -> pause-after-preprocessing 이 Succeeded 가 되고 다음 노드가 Running 이어야 함

# 4) 새 워크로드가 end-to-end로 Succeeded 되는가 (최종 합격 기준)
```

---

## 진단에 사용한 주요 명령 (재현용)

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide | grep -iE "orchestrator|scheduler|webhook|forecaster|policy|insight"
kubectl get events -A --field-selector type=Warning | tail -25
kubectl get storageclass
kubectl logs -n kube-system deploy/ai-storage-orchestrator --tail=15
kubectl logs -n apollo deploy/orchestration-policy-engine --tail=15
kubectl get cm ai-storage-orchestrator-config -n kube-system -o yaml
kubectl get orchestrationpolicy -n apollo --no-headers | wc -l
kubectl get wf -n ai-storage-workloads <run> -o json   # status.nodes[*].{phase,displayName}
```
