# KETI AI Storage System — 아키텍처 & 라이브 검증

> 작성일: 2026-06-16 · 대상 클러스터: `ai-storage-master` (10.0.4.80)
> 이 문서는 워크스페이스 코드 분석 + 라이브 클러스터 end-to-end 검증 결과를
> 종합한 것이다. 프로젝트 작성자의 9-모듈 목록을 실제 코드/배포 기준으로
> 교정하고, 시스템이 실제로 동작하는지 검증한 결과와 발견된 버그의 근본
> 원인을 기록한다.

---

## 0. 한 줄 요약

스토리지 I/O·CSD를 1급 자원으로 다루는 AI/ML용 Kubernetes 오케스트레이션
시스템. **배치(스케줄링)는 `ai-storage-scheduler`**, **정책 두뇌는 APOLLO의
`scheduling-policy-engine`(PPO RL)**, **사후 조정(마이그레이션·스케일·캐싱)은
`ai-storage-orchestrator`**가 담당한다. 전체가 클러스터에 배포되어 동작하나,
**APOLLO PPO 엔진은 proto 스키마 불일치로 현재 정책 생성에 실패**하고 있어
스케줄러는 기본 가중치로 폴백 중이다(§5, §6).

---

## 1. 모듈 맵 (작성자 목록 교정본)

| # | 모듈 | 위치 | 언어 | 실제 핵심코드 | 역할 | 노출 포트 |
|---|---|---|---|---|---|---|
| 1 | ai-storage-scheduler | `/ai-storage-scheduler` | Go | `cmd`, `internal/scheduler`, `internal/framework/plugin`(27개) | 스토리지/CSD/티어/로컬리티 인식 커스텀 스케줄러 (Filter/Score/Bind) | — (스케줄러) |
| 2 | ai-storage-orchestrator | `/ai-storage-orchestrator` | Go | `cmd`, **`pkg`(컨트롤러 8종)**, `api`(CRD) | 마이그레이션·로드밸런싱·프리엠션·오토스케일·프로비저닝·캐싱 등 사후 조정 | HTTP :8080, gRPC :50051(ETRI) |
| 3 | ai-storage-webhook | `/ai-storage-webhook` | Go | `cmd`, `pkg/webhook` | Pod/PVC Admission. schedulerName·insight-trace 사이드카 주입, PVC 티어(L1~S3) 결정 | HTTPS :443 |
| 4 | ai-storage-metric-collector | `/ai-storage-metric-collector` | Go | `cmd`, **`pkg`** | 노드 CPU/메모리/디스크(gopsutil) + GPU(DCGM) 수집 | :2112 |
| 5 | orchestration-policy-engine | `/apollo/orchestration-policy-engine` | Go (kubebuilder) | `internal/controller`(8), `internal/operator`(2) | `OrchestrationPolicy` CRD 조정 → orchestrator에 실행 위임 | gRPC :50056, :9092 |
| 6 | node-resource-forecaster | `/apollo/node-resource-forecaster` | Python | `server`, `models` | LSTM-Attention 노드 리소스 예측 + LightGBM 7개 결정 모델 | gRPC :50055, :9091 |
| 7 | insight-hub | `/insight-hub` | **Go** | `cmd`, `internal/store`(SQLite) | **자원 스냅샷 이력 + 정책 실행 결과** 저장/질의 | gRPC :50056, HTTP :8081 |
| 8 | insight-scope | `/insight-scope` | **Go** | `cmd`, `pkg` | 클러스터/노드 메트릭 수집(DaemonSet) + Pod YAML 정적분석/모델탐지 | gRPC :50054, HTTP :9092 |
| 9 | insight-trace | `/insight-trace` | **Go** | `cmd`, `pkg/sidecar` | 워크로드 런타임 추적 사이드카 → APOLLO로 WorkloadSignature 보고 | HTTP :9090, gRPC :9091 |
| ★ | **scheduling-policy-engine** | `/apollo/scheduling-policy-engine` | Python | `server`, `models/ppo.py` | **PPO 강화학습 → 스케줄러 플러그인 5종 가중치 산출 (실제 스케줄링 두뇌)** | gRPC :50054 |
| ★ | **APOLLO Go 게이트웨이** | `/apollo` (`cmd`,`pkg`) | Go | `pkg/grpc`, `pkg/scheduling` | gRPC 진입점·시그니처 수신·**규칙 기반** 정책(PPO 부재 시 폴백 구현) | gRPC :50051 |

### 작성자 목록 대비 교정 사항
- **#2 orchestrator·#4 metric-collector의 `internal/`은 빈 폴더**(.go 0개)다.
  "핵심 코드"로 보기 어렵다. 실제 핵심은 **`pkg/`**.
- **#7 insight-hub은 "trace/forecast/policy 결과 저장"이 아니다.** SQLite에
  실제로 저장하는 것은 ① **resource_snapshots**(노드/Pod 자원 사용 이력,
  insight-scope가 송신) ② **orchestration_results**(정책 실행 결과, HTTP 수신)
  두 가지다. **trace 원본은 insight-trace가 APOLLO로 직송**하며 hub를 거치지
  않고, forecast(예측값) 저장은 확인되지 않았다.
- **작성자 목록에 누락**: ★ 표시한 **scheduling-policy-engine(PPO RL)**과
  **APOLLO Go 게이트웨이**가 실제 스케줄링 정책 두뇌인데 목록에 없다. 반드시 추가.
- **언어 오해 주의**: insight-hub/scope/trace는 모두 **Go** 구현이다.
  apollo README 다이어그램이 insight-trace를 Python처럼 그린 것은 부정확하다.

---

## 2. 데이터 흐름

```
insight-scope (노드 메트릭 / Pod YAML 정적분석) ─┐
insight-trace (런타임 시그니처, 사이드카) ───────┼─▶ insight-hub (SQLite 이력 저장)
                                                 │            │
ai-storage-webhook                               │            ▼
 (schedulerName · 사이드카 · PVC 티어 주입)       │    node-resource-forecaster
        │                                        │     (LSTM-Attention + LightGBM)
        ▼                                        ▼            │ 예측 · 정책 추천
  ai-storage-scheduler  ◀── PPO 플러그인 가중치 ── scheduling-policy-engine (PPO RL, :50054)
  (스토리지 / CSD / 티어 인식 배치)  ── 결과 피드백 ▶        │
        │ 배치 완료                                          ▼
        ▼                                          orchestration-policy-engine (CRD)
  ai-storage-orchestrator  ◀────── OrchestrationPolicy ────── (마이그/스케일/캐싱 결정)
  (사후 조정 실행)
```

핵심 계약(라벨/어노테이션/schedulerName):
- webhook이 Pod에 `schedulerName=ai-storage-scheduler`, `ai-storage-selected-tier`,
  insight-trace 사이드카, `shareProcessNamespace=true`를 주입.
- insight-trace가 30초마다 `WorkloadSignature`(I/O 패턴·stage·GPU 여부)를 APOLLO로 송신.
- scheduler가 APOLLO `GetSchedulingPolicy`로 플러그인 가중치를 받고, 배치 후
  `ReportSchedulingResult`로 피드백(보상 입력).

---

## 3. 포트 맵 (네임스페이스 간 번호 충돌 주의)

| 포트 | 컴포넌트 | 비고 |
|---|---|---|
| :50054 | scheduling-policy-engine (gRPC) **그리고** insight-scope (gRPC) | **번호 중복** — ns가 달라 충돌은 없으나 혼동 주의 |
| :50056 | insight-hub (gRPC) **그리고** orchestration-policy-engine (gRPC) | **번호 중복** — 동상 |
| :50055 | node-resource-forecaster (gRPC) | |
| :50051 | APOLLO Go 게이트웨이 (gRPC) | scheduler 코드 기본값이자 webhook 사이드카가 가리키는 곳 |
| :2112 | ai-storage-metric-collector | Prometheus `/metrics` + JSON `/gpu` |
| :8080 | ai-storage-orchestrator (HTTP) | REST API |
| :8081 | insight-hub (HTTP) | 정책 결과 ingest |
| :9090/:9091 | insight-trace (HTTP / gRPC) | 사이드카 |
| :9092 | insight-scope (HTTP) | |

---

## 4. 컴포넌트 성숙도 (REAL / 규칙기반 / 스텁)

| 컴포넌트 | 구현 수준 | 비고 |
|---|---|---|
| scheduling-policy-engine | **진짜 PPO RL** (PyTorch Actor-Critic, GAE, clip, 온라인 학습) | 사전학습 가중치가 repo에 없어 콜드스타트. **현재 런타임 버그로 실패(§6)** |
| node-resource-forecaster | **진짜 LSTM-Attention** (멀티헤드 어텐션, 멀티 horizon) | LightGBM 7모델은 모델파일 부재 시 규칙 임계값 폴백 |
| ai-storage-scheduler | **REAL** — DataLocalityAware/StorageTierAware/IOPatternBased/CSIStorageAware/ShardAware | 라이브 검증됨(§5) |
| ai-storage-webhook | **REAL** — 티어 AHP 가중 점수 + 하드룰 + 사이드카 주입 | 라이브 검증됨(§5) |
| ai-storage-orchestrator (8 컨트롤러) | 대부분 **REAL** | 캐싱 통계는 시뮬레이션, 상태는 인메모리(재시작 시 유실) |
| APOLLO Go 게이트웨이 | **규칙 기반**(ML 아님) | 보상 계산만 하고 학습엔 미사용. ForecastService는 빈 스텁 |
| ai-storage-orchestrator `pkg/gluesys` | **스텁** | `log.Printf`만, 실제 Gluesys 호출 없음 |
| ai-storage-orchestrator `pkg/manta` | gRPC 연결 인프라만 | 모든 RPC `NotImplemented` (TODO) |

---

## 5. 라이브 검증 결과 (2026-06-16)

전체 시스템이 클러스터에 배포되어 **부분 동작 중**임을 확인했다. 검증용 Pod
`e2e-verify-probe`를 injection-enabled 네임스페이스(`ope-model-verify`)에
투입해 관찰한 뒤 정리했다.

### ✅ 정상 동작 확인
| 항목 | 증거 |
|---|---|
| webhook 변형 | probe에 `schedulerName=ai-storage-scheduler` + insight-trace 사이드카 주입(컨테이너 2개) + `shareProcessNamespace=true` + 티어 라벨. webhook 로그 "Applying 12 patches to Pod" |
| scheduler 스토리지 인식 배치 | `CSIStorageAware` 등 Score 플러그인 실행 → 노드 점수(`ai-storage-master:1238` vs `ai-storage-worker-01:1307`) → worker-01 선택 → `DefaultBinder` 바인딩 성공 |
| scheduler → APOLLO 피드백 | scheduler `[APOLLO-Feedback] ... success=true` 송신 / APOLLO `SchedulingResult: request_id=ad318175..., success=True` 수신 |
| insight-trace → APOLLO | 30초 주기 `[APOLLO] WorkloadSignature sent` 송신 |
| forecaster ML 파이프라인 | insight-hub에서 노드 이력 pull(`total_samples=1440`) → LSTM `Forecast completed` → LightGBM `GetPolicyRecommendations` |
| orchestrator | `/health` 200 응답, demo-lb/migration 데모 워크로드 처리 흔적 |

### 🔴 발견된 문제
1. **APOLLO PPO 정책 생성이 모든 Pod에서 실패 (최우선)** — §6 참조.
   결과적으로 scheduler가 PPO 가중치를 못 받고 `weight_source=default`로 폴백.
   → **ML 두뇌가 실질적으로 비활성**(배치 자체는 기본 가중치로 성공).
2. **APOLLO 엔드포인트 불일치**: scheduler는 `scheduling-policy-engine.apollo.svc:50054`(PPO),
   webhook 사이드카는 `apollo-policy-server.keti.svc:50051`(Go 게이트웨이)를 가리킴.
3. **중복 배포**: `scheduling-policy-engine`이 `apollo`/`keti` 양쪽 ns에,
   Go 게이트웨이(`apollo-policy-server`)도 `keti`에 별도 존재. 정본 불명확.
4. **worker-01 `NotReady`인데 scheduler가 그 노드에 바인딩** — 스케줄러 캐시와
   실제 노드 상태 불일치. 스케줄 가능 노드가 master 1개로 축소되어 forecaster가
   `Insufficient history 28/60` 경고.
5. **forecaster 과거 1628회 재시작**(14일 전까지 누적). 현재는 안정 동작.

---

## 6. 근본 원인 진단 — APOLLO PPO 버그

라이브 에러:
```
ERROR:__main__:[PolicyEngine] Error generating policy:
Protocol message WorkloadSignature has no "dataset_name" field.
  File "/app/server/grpc_server.py", line 358, in GetSchedulingPolicy
```

코드까지 추적한 결과:

- **Go scheduler가 기대하는 응답 타입**은 `SchedulingPolicy.workload_signature`
  (field 20) → **`WorkloadSignatureInfo`** 메시지. 이 메시지는 `dataset_name`(13),
  `data_locations`(14), `preprocessing_type`(12), `cached_on_nodes`(15) 등 15개
  필드를 가진다. (증거: `ai-storage-scheduler/internal/apollo/apollo.pb.go:698-714`)
- **Python 엔진의 `apollo.proto`에는 `WorkloadSignatureInfo` 메시지가 없다.**
  `SchedulingPolicy`(line 138)에 `workload_signature` 필드 자체가 없고,
  `WorkloadSignature`(line 18)는 insight 수집 전용 별개 메시지(`dataset_name` 없음).
- Python `server/grpc_server.py:1167~1180`이 응답을 만들 때 **잘못된
  `WorkloadSignature` 메시지에 `dataset_name=`, `data_locations=`를 채우려다
  ValueError** → 모든 `GetSchedulingPolicy`가 실패한다.
- **정본 `.proto`가 워크스페이스에 없다.** 어떤 `apollo.proto`에도
  `WorkloadSignatureInfo`가 정의되어 있지 않고 Go `apollo.pb.go`만 신버전이다.
  → Go와 Python 간 proto 스키마 정합성 전체가 틀어진 상태.
- `dataset_name`/`data_locations`는 **데이터 로컬리티 보상(+0.5) 계산에 실사용**
  된다(`server/grpc_server.py:1243`). 따라서 필드를 제거하는 게 아니라 **추가**가
  올바른 방향이다.
- 배포 이미지가 `imagePullPolicy: Never`이므로 수정 시 **로컬 이미지 재빌드 +
  containerd import + Pod 재시작**이 반드시 필요하다.

---

## 7. 권장 후속 수정 (Recommended Fixes)

> 본 문서는 진단·기록용이며, 아래 수정은 별도 작업으로 진행한다.

- [ ] **(핵심) proto 정합**: Python `apollo.proto`에 Go 정본과 동일한
  `WorkloadSignatureInfo` 메시지를 추가하고 `SchedulingPolicy.workload_signature`
  (field 20)를 연결 → `protoc` 재생성 → 이미지 재빌드 → 재배포.
  이것이 PPO 두뇌를 활성화하는 핵심이다.
- [ ] scheduler vs webhook의 `APOLLO_ENDPOINT` 일원화 (`:50051` Go 게이트웨이
  vs `:50054` PPO 중 정본 선택).
- [ ] `keti`/`apollo` 네임스페이스 중복 배포 정리(정본 1개로).
- [ ] `ai-storage-worker-01` `NotReady` 복구 또는 스케줄러 캐시 동기화 점검.
- [ ] PPO/LightGBM 사전학습 체크포인트 제공으로 콜드스타트 해소.

---

## 8. 검증 재현 절차

1. 배포 상태: `kubectl get pods,svc -A | grep -iE "scheduler|apollo|insight|orchestrator|webhook|forecaster"`
2. CRD: `kubectl get crd | grep -iE "keti|apollo"` (`storagehpas`, `orchestrationpolicies`, `aistorageconfigs`)
3. end-to-end probe: injection-enabled ns(예: `ope-model-verify`)에 busybox Pod 투입
   → webhook 2-컨테이너 변형 확인 → scheduler 로그에서 Score 점수·노드 선택·
   `APOLLO-Feedback` 확인 → Pod 정리.
4. PPO 버그 재확인:
   `kubectl logs -n apollo deploy/scheduling-policy-engine | grep "Error generating policy"`
5. 데이터 흐름: insight-trace(`WorkloadSignature sent`), forecaster(`Forecast completed`),
   orchestrator(`/health` 200) 로그 확인.
