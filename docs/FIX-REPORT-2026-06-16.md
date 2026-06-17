# KETI AI Storage — 진단·수정·검증 종합 보고서

> 작업일: 2026-06-16 · 대상: 99 클러스터(cpu-master-server / csd-server-01 / gpu-server-03)
> 빌드 환경: 80 서버(개발 전용) · 배포·검증: 99 서버(실 운영) · SSH+NFS로 80→99 자동화

---

## 1. 요약 (TL;DR)

라이브 클러스터에서 **6개 결함을 진단·수정·배포·검증**하고, 실제 ML 파이프라인이
**end-to-end로 완주(Succeeded)** 함을 입증했다. 8일간 멈춰 있던 오케스트레이션이
실제 액션을 실행하기 시작했고, 무한 실패하던 PVC가 정상 Bound되었다.

| # | 결함 | 상태 |
|---|---|---|
| PPO | APOLLO PPO 엔진이 proto 스키마 불일치로 모든 스케줄링 정책 생성 실패 | ✅ 수정·배포·검증 |
| ISSUE-1 | orchestrator가 존재하지 않는 SC `high-throughput` 하드코딩 → PVC 무한 실패 | ✅ 수정·배포·검증 |
| ISSUE-2 | OrchestrationPolicy가 100% `delay` + CR GC 부재 → 5천+ 누적 | ✅ 수정·배포·검증 |
| ISSUE-2b | policy-engine→orchestrator provisioning 요청 계약 불일치(400) | ✅ 수정·배포·검증 |
| ISSUE-5 | 누적 CR 5,348개 운영 정리 | ✅ 정리 |
| ISSUE-3 | 파이프라인 pause 게이트 정지 | ✅ **버그 아님 — 시연용 수동 게이트** |
| ISSUE-4 | 노드 버전 스큐(csd-server-01 v1.29) | ⏸️ 보류(인프라, 절차 문서화) |

---

## 2. 시스템 동작 과정 (전체 흐름)

```
┌─ 워크로드 생성 (Pod/Workflow)
│
├─[1] ai-storage-webhook (Admission)
│      · schedulerName="ai-storage-scheduler" 주입
│      · insight-trace 사이드카 주입 + shareProcessNamespace
│      · PVC 스토리지 티어(L1/L2/L3/S3) AHP 점수로 결정
│
├─[2] ai-storage-scheduler (배치 결정)
│      · APOLLO(scheduling-policy-engine:50054)에 정책 질의
│      ·   → PPO 강화학습이 플러그인 5종 가중치 산출 (weight_source=APOLLO)
│      · Filter: 스토리지 티어·CSD·데이터 로컬리티로 노드 후보 선별
│      · Score: I/O 패턴↔티어 매칭으로 점수 → 최적 노드 선택
│      · 배치 결과를 APOLLO에 피드백(ReportSchedulingResult) → PPO 학습
│      · 메트릭: ai-storage-metric-collector(:2112), insight-trace(사이드카)
│
├─[3] ai-storage-orchestrator (사후 조정)
│      · provisioning: tier→SC 매핑(ConfigMap) 으로 PVC 생성 → Bound
│      · autoscaling / loadbalancing / preemption / caching / migration
│
└─[4] APOLLO 정책 엔진들
       · scheduling-policy-engine (PPO): 스케줄러 가중치
       · node-resource-forecaster (LSTM): 노드 리소스 예측
       · orchestration-policy-engine (CRD): OrchestrationPolicy 생성·승인
         → approve 시 orchestrator API 호출(autoscaling/provisioning 등)
         → 종료 정책은 GC가 TTL 후 정리

데이터 수집: insight-scope(노드/YAML) + insight-trace(런타임) → insight-hub(SQLite)
                                                              → forecaster가 이력 학습
```

### 실 워크로드 파이프라인 (검증된 흐름)
```
preprocessing → [pause] → storage → [pause] → training → [pause] → inference
   (GPU노드)              (CSD노드)            (GPU노드)            (CPU노드)
```
- 각 단계 사이 `pause-*`(Argo Suspend)는 **시연용 수동 게이트** —
  발표자가 `argo resume`으로 진행. 버그 아님.
- **스토리지 인식 차등 배치**가 핵심: storage는 CSD 노드, training은 GPU 노드로
  워크로드 특성에 맞게 자동 배치됨(라이브 입증).

---

## 3. 결함별 상세 (근본원인 → 수정 → 검증)

### PPO — APOLLO 정책 생성 실패
- **원인:** Python `apollo.proto`가 Go scheduler 정본보다 구버전. ①`SchedulingPolicy`에
  `workload_signature`(field 20) 필드 부재 ②`WorkloadSignatureInfo` 메시지 자체 부재
  ③`plugin_weights` field 번호 불일치(Python 15 vs Go 13, wire 비호환).
  코드(`grpc_server.py`)는 신버전 가정 → `ValueError: WorkloadSignature has no
  "dataset_name" field` → 모든 `GetSchedulingPolicy` 실패.
- **수정:** `apollo/scheduling-policy-engine/proto/apollo.proto`에 `WorkloadSignatureInfo`
  메시지 + `PreprocessingType` enum 추가, `plugin_weights`=13으로, `workload_signature`=20
  연결. `grpc_server.py` 빌더가 `WorkloadSignatureInfo` 반환하도록 1줄 수정.
- **검증:** `Error generating policy` 0건, scheduler 로그 `weight_source=APOLLO` 출현.

### ISSUE-1 — 존재하지 않는 SC `high-throughput`
- **원인:** orchestrator 바이너리에 SC명 하드코딩. 클러스터엔 storage-l1/l2/l3/s3만 존재
  → PVC가 `high-throughput` 요청 → `storageclass not found` 1분마다 8일째 반복.
- **수정(창 A):** `ai-storage-orchestrator/pkg/controller/provisioning.go` — tier→SC 매핑을
  ConfigMap(`config.yaml`)에서 읽도록 설정화(L1→storage-l1 … default storage-l2).
  `validateRequest`로 잘못된 SC를 400으로 사전 차단.
- **운영 핫픽스:** `high-throughput` SC alias(→storage-l2) 생성으로 즉시 실패 중단.
- **검증:** `not found` 이벤트 0건.

### ISSUE-2 — 100% delay + CR 누적
- **원인:** policy-engine의 approve 게이트가 raw `probability`(예 44)와 비교 →
  `urgency=HIGH, priorityScore=84`(이미 합성값)인 정책도 영원히 delay. + 종료 CR
  GC 부재로 무한 누적(분당 ~3개 → 일 ~3,400개).
- **수정(창 B-1):** `internal/policyagent/client.go` — priorityScore가 충분하면 approve.
  `internal/controller/gc.go` 추가 — 종료(Completed/Failed/Rejected) CR을 TTL(10분)
  후 5분 주기로 삭제.
- **검증:** `action=approve` 출현, phase 분포 Pending 1534→59 / Approved·Executing 급증,
  GC `Deleted terminated OrchestrationPolicy` 로그, autoscaling 201 × 1,462건 실행.

### ISSUE-2b — provisioning 계약 불일치(400)
- **원인:** ISSUE-2 수정으로 approve가 흐르자, policy-engine이 orchestrator
  `POST /provisioning`에 보내는 요청이 창 A의 강화된 검증(필수 필드 + SC 화이트리스트)과
  불일치 → 400. (병렬 작업에서 발생한 인터페이스 충돌)
- **수정(창 B-2):** `internal/operator/client.go`, `internal/generator/policy_generator.go` —
  요청 페이로드를 새 계약(workload_name/namespace/type + tier L1~S3)에 맞춤.
- **검증:** provisioning **400→201** 전환, PVC가 `tier=L2, sc=storage-l2`로 **Bound(100Gi)**.
  8일 Pending이던 `pvc-workflow-controller-provisio` 정상화.

### ISSUE-5 — CR 5,348개 정리(운영)
- 종료 상태 CR 3,800여 개를 phase 필터로 안전 삭제(진행 중은 보존). 이후 ISSUE-2의
  GC가 자동 정리 담당.

### ISSUE-3 — pause 게이트 (정정: 버그 아님)
- `step-pause-keti-orchestration.sh`(99) 분석 결과 **39단계 시연 wrapper**의 의도된
  수동 게이트(`suspend: {}` = 무한 수동 대기). `argo resume`으로 진행시키면 다음 단계
  실행. 라이브로 4단계 전부 resume → 파이프라인 **Succeeded** 완주 입증.

### ISSUE-4 — 노드 버전 스큐 (보류)
- csd-server-01: Ubuntu 18.04(EOL) + kubelet v1.29(control-plane 1.34와 5단계 차).
  고위험 인프라 작업이라 보류, 절차는 `docs/ISSUE-4-node-upgrade-plan.md`에 문서화.

---

## 4. 라이브 검증 — end-to-end 완주

테스트 워크플로 `ai-storage-main-pipeline-run-20260616-135621`를 게이트 resume하여 완주.

```
workflow phase: Succeeded
  [Succeeded] preprocessing  (node=gpu-server-03)
  [Succeeded] storage        (node=csd-server-01)   ← CSD 노드
  [Succeeded] training       (node=gpu-server-03)   ← GPU 노드
  [Succeeded] inference      (node=cpu-master-server)
```
- scheduler 로그 `weight_source=APOLLO` (PPO 가중치 실제 적용)
- 모든 PVC `storage-l2/l1/l3`로 Bound
- Kueue `Admitted by clusterQueue ai-storage-cluster-queue`

---

## 5. 배포 메커니즘 (80 빌드 → 99 배포)

- 80(개발) ─NFS(`/mnt/nfs-volume`)─ 99(운영). 80→99 SSH 키 등록으로 자동화.
- 흐름: 80에서 `docker build`/`make docker-build` → `docker save` → NFS →
  99에서 `ctr -n k8s.io images import` → `kubectl set image`/`rollout restart`.
- 이미지 태그: PPO·orchestrator는 `:latest`(Never), policy-engine은
  `issue2-prov-20260616`(고유 태그로 IfNotPresent 캐시 회피).

---

## 6. 남은 작업 / 후속 권고

- **ISSUE-4 노드 업그레이드** (보류) — `docs/ISSUE-4-node-upgrade-plan.md`.
- **git 커밋** — 수정한 proto/소스는 워크스페이스에만 있음(명시 요청 시 커밋).
  대상 repo: `apollo`(scheduling-policy-engine, orchestration-policy-engine),
  `ai-storage-orchestrator`.
- **운영 alias 정리** — 창 A의 SC 설정화가 근본 해결이므로, 임시 `high-throughput`
  SC alias는 추후 제거 가능(단, 다른 컴포넌트가 안 쓰는지 확인 후).
- **autoscaling 유령 타깃** — 존재하지 않는 deployment를 스케일하려는 로그 관측.
  정책 생성기가 타깃 워크로드 존재를 검증하도록 개선 권고(사소, 별개).

---

## 6.5 시연 스크립트(run-all-steps.sh) 검증 + ArgoCD include 수정

시연 자동 실행 스크립트를 돌려 전체 흐름을 검증. 처음엔 FAIL 20개였으나
**근본 원인이 ArgoCD application의 `include` 필터**임을 규명·수정하여 FAIL 3개로 감소.

### 근본 원인 (시연 환경 설정)
- ArgoCD application `ai-storage-pipeline`의 소스 설정:
  `spec.source.directory.include = "ai-storage-main-pipeline.yaml"` — **단 한 파일만 추적.**
- 시연이 새로 제출하는 워크플로(`storage-workload.yaml` 등)는 Git에 있어도 ArgoCD가
  **무시** → 새 워크로드 Pod 미생성 → 의존 단계(15/17/18 등) "워크로드 없음"으로 FAIL.
- 이는 **우리 코드 수정과 무관한 시연 GitOps 설정 문제.**

### 수정
- `include`를 `{ai-storage-main-pipeline.yaml,storage-workload.yaml}`로 변경
  (kubectl patch). → `argocd app sync`로 새 워크플로 `cpu-cifar10-storage-run-*`이
  클러스터에 생성·Succeeded. (argocd CLI는 admin/포트8080으로 재로그인)

### 결과 (1차 → 재실행)
| 지표 | 1차 | include 수정 후 |
|---|---|---|
| PASS | 34 | **36** |
| FAIL | **20** | **3** |
| 15-Forecaster | FAIL | ✅ PASS |
| 16-Scheduling-Policy(PPO) | PASS | ✅ PASS |
| 33/34/35 (after 단계) | 미도달 | ✅ 전부 PASS |

### 남은 FAIL 3개 (우리 수정 무관, 워크로드 특성/타이밍)
- **08-Kueue / 18-Orchestrator-apply:** storage 워크로드가 너무 빨리 종료
  (`finished=1/1`)되어 "적용 순간"을 못 잡는 타이밍 이슈.
- **14-Preprocessing-Pipeline-Integration:** `storage` 워크로드로 실행했는데
  preprocessing 전용 단계라 타입 불일치(시연 인자 선택 문제).
- 핵심 오케스트레이션 로직(16 PPO, 33/34/35 after 단계)은 전부 PASS → 우리 수정 정상.

### 권고
- ArgoCD `include`를 워크로드 타입별로 동적 설정하거나 디렉토리 전체 recurse로
  바꾸면 시연이 새 워크플로를 항상 자동 배포. (현재 patch는 storage만 추가한 상태)

---

## 7. 백업 위치

- PPO 수정 전 원본: `apollo/scheduling-policy-engine/.backup-ppo-fix-20260616-172216/`
- 빌드 이미지 tar: `/root/scheduling-policy-engine-fixed.tar` 등
- 분담/이슈 문서: `PARALLEL-WORK-SPLIT.md`, `ORCHESTRATION-ISSUES.md`, `docs/ARCHITECTURE.md`
