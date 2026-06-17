# 병렬 작업 분리 가이드

> 생성: 2026-06-16 · 목적: ORCHESTRATION-ISSUES.md의 잔여 근본수정을 여러 창에서
> 충돌 없이 동시에 진행하기 위한 분담표 + 각 창 시작 프롬프트.
>
> **배경(이미 완료된 것):** PPO 버그 수정 후 99 배포·검증 완료(scheduling-policy-engine).
> ISSUE-1 우회책(high-throughput SC alias)·ISSUE-5(CR 3,807개 정리) 운영 핫픽스 완료.
> 80→99 SSH 자동화 구성됨(`ssh root@10.0.4.99`, `~/.kube/config-99`).

---

## 충돌 방지 규칙 (모든 창 공통 — 반드시 지킬 것)

1. **클러스터 변경(kubectl apply/delete/rollout)은 "운영 창" 한 곳에서만.**
   소스 창들은 코드 수정 + 빌드까지만. 배포는 운영 창에 요청.
2. **git 커밋도 repo별 담당 창에서만.** 같은 repo를 두 창이 커밋하면 충돌.
   - `apollo` repo: **창 B가 담당** (orchestration-policy-engine + 기존 scheduling-policy-engine 미커밋 변경 포함)
   - `ai-storage-orchestrator` repo: **창 A가 담당**
3. **99 배포 이미지 태그는 `:latest` 공유 + containerd import** 방식.
   동시에 같은 이미지를 빌드/배포하지 말 것(운영 창이 순서 조율).
4. 작업 시작 전 각 창은 이 파일 + `ORCHESTRATION-ISSUES.md`를 읽을 것.

---

## 레포 경계 (확인됨)

| 컴포넌트 | 경로 | git |
|---|---|---|
| orchestrator | `ai-storage-orchestrator/` | 독립 repo |
| apollo (policy/scheduling 엔진) | `apollo/` | 독립 repo (orchestration-policy-engine 포함) |

→ **창 A(orchestrator repo)와 창 B(apollo repo)는 다른 repo라 커밋 충돌 없음.**
미커밋 주의: `apollo` repo에 PPO 수정(scheduling-policy-engine proto/py)이 아직
커밋 안 됨 → 창 B가 apollo repo 커밋 시 이것도 함께 다루거나 분리 커밋.

---

## 창 A — ISSUE-1 근본수정 (orchestrator SC 하드코딩 제거)

**Repo:** `ai-storage-orchestrator/` · **클러스터 변경 없음(빌드까지)**

**핵심 위치:**
- orchestrator가 PVC 만들 때 `high-throughput` SC를 쓰는 실제 로직.
  `pkg/controller/provisioning.go`의 storage class 선택/할당 부분
  (`selectStorageClass`, `CreateProvisioning`, `executeProvisioning` 추적).
  주의: `provisioning.go:673`은 주석/Reasoning 문자열일 뿐 — 실제 PVC에 들어가는
  storageClassName이 어디서 결정되는지 따라가야 함. `high-throughput`이
  바이너리에 하드코딩됐는지, 워크로드타입→SC 매핑 테이블에서 오는지 확정.
- 실제 클러스터 SC는 `storage-l1/l2/l3/s3`만 존재(high-throughput 없음).

**목표:** 하드코딩 제거 → ConfigMap(`config.yaml`)에서 읽도록 설정화.
예: `provisioning.default_storage_class: storage-l2` 또는 tier→SC 매핑.
임시로는 `high-throughput`→`storage-l2` 상수 교체도 가능(문서 ISSUE-1 참고).

**완료 기준:** 코드 수정 + `go build` 통과 + 이미지 빌드. 배포는 운영 창에 인계.

---

## 창 B — ISSUE-2 근본수정 (policy-engine always-delay + CR GC)

**Repo:** `apollo/` · **클러스터 변경 없음(빌드까지)**

**핵심 위치:** `apollo/orchestration-policy-engine/internal/policyagent/client.go`
- `:182` approve 조건(`priorityScore and probability meet standard approval threshold`)
- `:186` 여기로 빠짐(`policy remains below forecaster-aligned approval threshold`)
- **의심 포인트(문서 추정보다 우선 점검):** `urgency=HIGH, priorityScore=84`인데도
  delay라면, `:182`의 비교가 **잘못된 필드/스케일**일 가능성. approve 임계값이
  상수인지 forecaster 출력과 비교하는지, 단위(%, 0~1)가 맞는지 확인.
- forecaster 출력값도 함께 확인: `kubectl logs -n apollo deploy/node-resource-forecaster`.

**추가:** CR GC — 종료(Completed/Failed/Rejected)된 OrchestrationPolicy를
TTL 또는 reconcile 후 정리하는 로직 추가(없으면 고쳐도 다시 누적됨).
reconcile 위치: `apollo/orchestration-policy-engine/internal/controller/orchestrationpolicy_controller.go`.

**완료 기준:** 코드 수정 + 빌드. 배포는 운영 창에 인계.
**커밋 주의:** apollo repo엔 PPO 미커밋 변경 있음 → 별도 커밋으로 분리.

---

## 창 C (운영) — 배포·검증·인프라

**클러스터 변경 담당 창 (kubectl/ssh).** SSH 자동화 가능: `ssh root@10.0.4.99`.

**할 일:**
1. 창 A·B가 빌드한 이미지를 99에 배포(이제 SSH로 원샷 가능):
   `docker save` → `scp root@10.0.4.99:` 또는 NFS → `ssh root@10.0.4.99 'ctr -n k8s.io images import ...'`
   → `kubectl --kubeconfig ~/.kube/config-99 rollout restart ...`
2. 배포 후 검증(ORCHESTRATION-ISSUES.md "검증 절차"):
   - ProvisioningFailed 멈춤 / CR이 delay 외 action 나오는지 / CR 수렴
3. **ISSUE-4**(노드 버전 스큐): csd-server-01 v1.29→1.31+ 업그레이드(인프라, 독립 작업).
4. ISSUE-2 미수정 동안 Pending CR 재누적 모니터링(필요시 주기적 정리).

---

## 진행 현황 보드 (각 창이 갱신)

| 이슈 | 담당 창 | 상태 |
|---|---|---|
| PPO dataset_name 버그 | (완료) | ✅ 수정·배포·검증 끝 |
| ISSUE-1 우회책(SC alias) | (완료) | ✅ |
| ISSUE-5 CR 정리 | (완료) | ✅ 5348→1541 |
| SSH 자동화 | (완료) | ✅ |
| **ISSUE-1 근본수정** | 창 A | ✅ 수정·빌드·99배포·검증 완료 (아래 주의) |
| **ISSUE-2 근본수정** | 창 B | ✅ 수정·빌드·99배포·검증 완료 (delay→approve, GC 동작) |
| **ISSUE-4 노드 업그레이드** | 창 C | ⬜ 시작 전 |
| 배포·검증 | 창 C | ⬜ A·B 대기 |

## 운영 창 모니터링 데이터 (창 B 참고용)

**CR 재누적 속도(2026-06-16 18:53~18:58 측정):** 분당 ~2~3개 → 하루 ~3,400개.
- Pending은 거의 안 늘고(+3) 총합만 늘어남(+12) → 새 CR이 잠깐 Pending 후
  종료 상태로 전이되나 **GC가 안 됨**. 즉 누적의 주범은 always-delay보다
  **종료 CR 미정리(GC 부재)**. → 창 B는 GC 로직 추가를 우선 고려할 것.
- ISSUE-1 SC alias 효과: high-throughput 'not found' 이벤트 0건(완전 해소 지속).

## 창 A 배포 결과 + 창 A↔B 인터페이스 충돌 (창 B 필독)

**ISSUE-1 배포 완료(2026-06-16 19:48, 99):** orchestrator 이미지 import +
ConfigMap(tier→SC 매핑: L1/L2/L3/S3, default storage-l2) 적용 + rollout. Running, restarts=0.
- tier→SC 설정화로 high-throughput 하드코딩 제거됨. 새 orchestrator는 잘못된
  storage_class를 `validateRequest`에서 400으로 거부(영구 Pending PVC 사전 차단).

**⚠️ 창 B 주의 — 인터페이스 계약 충돌:**
- `orchestration-policy-engine`(창 B 컴포넌트)이 새 orchestrator
  `POST /api/v1/provisioning`을 호출 → **400 반환** 관측됨.
- 원인: 새 orchestrator가 `workload_name/workload_namespace/workload_type` 필수 +
  `storage_class`를 L1/L2/L3/S3 화이트리스트로 검증. policy-engine이 보내는 요청이
  이 새 계약과 안 맞음(필드 누락 또는 high-throughput 같은 구 SC명 전송 추정).
- **창 B 할 일:** orchestration-policy-engine이 orchestrator로 보내는 provisioning
  요청 페이로드를 새 계약에 맞게 수정(필수 3필드 + tier는 L1~S3/legacy명).
  요청 생성 위치: `internal/operator/client.go` 또는 generator 쪽 provisioning 호출부.
- 현재는 policy-engine이 어차피 `action=delay`라 PVC 생성까지 안 가므로 즉시 장애는
  아님. 단 ISSUE-2(delay) 고치면 이 계약 불일치가 드러나니 함께 맞출 것.

## ★ ISSUE-2 배포 결과 + 계약충돌 현실화 (2026-06-16 20:27, 99)

**ISSUE-2 수정 배포·검증 완료:** orchestration-policy-engine 새 이미지
(`issue2-fix-20260616`) 빌드→99 import→deploy 태그 교체(컨테이너명=
`orchestration-policy-engine`, `manager` 아님 주의)→rollout. Running, restarts=0.
- **always-delay 해결**: `action=approve reason="high urgency with sufficient
  priorityScore approved"` 정상 출력. phase 분포 격변: Pending 1534→59,
  Approved 2→1014, Executing 2→565. 8일 정체 해소.
- **GC 동작 확인**: `Terminated policy GC started {interval:5m, ttl:10m, batchMax:200}`
  + `Deleted terminated OrchestrationPolicy` 로그. 종료 CR 자동 정리 시작.
- **autoscaling 실행됨**: orchestrator가 POST /autoscaling에 **201 × 1,462건**.
  실제 오케스트레이션 액션이 8일 만에 흐르기 시작.

**🔴 창 A·B 합동 후속 (계약충돌 현실화):**
- ISSUE-2 수정으로 approve가 흐르자 **provisioning 계약충돌이 드러남**:
  orchestrator POST /api/v1/provisioning에 **400 × 373건**(autoscaling은 201로 성공).
- 결과: `high-throughput` PVC가 42분째 그대로 Pending(provisioning 정책이 400으로
  막혀 새 PVC 생성/교체 안 됨). **스케일링은 살았으나 스토리지 provisioning만 막힘.**
- **창 B 할 일(미완):** orchestration-policy-engine이 orchestrator로 보내는
  provisioning 요청 페이로드를 새 계약에 맞출 것 —
  필수: `workload_name`, `workload_namespace`, `workload_type` /
  `storage_class`는 L1·L2·L3·S3 또는 legacy(burst/cache/performance/capacity/archive).
  요청 생성부: `internal/operator/client.go` 또는 generator의 provisioning 호출.
  → 고치면 재빌드 후 운영 창에 재배포 요청.
