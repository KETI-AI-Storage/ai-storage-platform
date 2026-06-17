# README_sinario2.md

## 1. 시나리오2 목표

자원/데이터/스토리지 특성을 반영한 정책 예측 및 오케스트레이션 자동화.

단계:

1. 수집
2. 자원 예측
3. 정책 후보 생성
4. 정책 영향도 평가
5. 정책 선택
6. 실행
7. 결과 저장

---

## 2. 현재 구현 상태 요약 표

기준: 실제 코드, 현재 배포 상태(`kubectl`), 런타임 로그.

| 단계명 | 관련 모듈 | 현재 상태 | 근거 파일 / 함수 / 로그 | 비고 |
|---|---|---|---|---|
| 1) 워크로드 / 자원 / I/O / 데이터 흐름 상태 수집 | `insight-scope`, `insight-trace`, `insight-hub` | 부분 구현 | 코드: `insight-scope/cmd/main.go`, `insight-scope/pkg/collector/metrics_collector.go`, `insight-trace/pkg/sidecar/sidecar.go`, `insight-hub/internal/grpc/server.go`. 배포: `kubectl get ds,deploy -n apollo`에서 `insight-scope`(Ready), `insight-trace`(Ready), `insight-hub`(Ready). 로그: scope는 `[ForecasterClient] Forecaster accepted ...` 출력, hub는 `[hub.ingest] STORED sqlite(legacy-forecaster-rpc)` 출력 | 수집 컴포넌트는 올라왔으나 hub non-legacy ingest 로그 미확인 |
| 2) 자원 사용량 및 스토리지 접근 패턴 예측 (LSTM-Attention) | `node-resource-forecaster` | 구현 완료 | 코드: `apollo/node-resource-forecaster/models/lstm_attention.py` (`LSTMAttentionForecaster`, `predict`), `apollo/node-resource-forecaster/server/http_server.py` (`/api/v1/forecast/node/<node>`). 헬스 로그: `lstm_attention_enabled=true`, `total_predictions` 증가 | 예측 경로 동작 확인 |
| 3) 정책 후보 생성 (Multi-LightGBM) | `node-resource-forecaster` | 부분 구현 | 코드: `apollo/node-resource-forecaster/models/multi_lightgbm.py` (`MultiLightGBMPolicyEngine`, `_load_models`, `predict`), `apollo/node-resource-forecaster/server/http_server.py` (`/api/v1/policy/*`) | 헬스에서 `policy_engine_enabled=true`이나 `policy_decisions=0` 상태 확인됨 |
| 4) 정책 영향도 평가 | `orchestration-policy-engine` | 부분 구현 | 코드: `apollo/orchestration-policy-engine/internal/controller/orchestrationpolicy_controller.go` (`Reconcile`, `handleExecutingPolicy`), `internal/operator/client.go`. 로그: `Reconciling OrchestrationPolicy`, `Monitoring executing policy` 반복 | 상태 전이/모니터링은 동작, 영향도 정량 평가 산출은 입증 근거 부족 |
| 5) 최적 정책 선택 | `orchestration-policy-engine` | 구현 완료 | 코드: `apollo/orchestration-policy-engine/internal/generator/policy_generator.go` (`runPolicyGeneration`, `analyzeAndCreatePolicy`, `createPolicyFromRecommendation`) | 정책 생성 루프와 CR 생성 동작 확인 |
| 6) 전처리 파이프라인 기반 오케스트레이션 실행 | `ai-storage-orchestrator` + OPE | 부분 구현 | 코드: `apollo/orchestration-policy-engine/internal/operator/client.go` (`StartMigration`, `ConfigureAutoscaling` 등), `ai-storage-orchestrator/pkg/apis/handler.go`, `ai-storage-orchestrator/pkg/controller/*.go`. 로그: `deployments.apps "all-workloads" not found`, rate-limit 에러 다수. 별도 테스트 로그에서 migration completed 확인 | migration 성공 사례 있음, autoscaling/provisioning 정합성 이슈 존재 |
| 7) 실행 결과 및 데이터 흐름 저장 / 학습 데이터 활용 | `insight-hub`, `node-resource-forecaster` | 부분 구현 | 코드: `insight-hub/internal/grpc/server.go` (`SubmitHistoryData`, legacy bridge), `insight-hub/internal/store/sqlite.go`. 로그: hub에 SQLite 저장 반복 확인 | 저장은 동작, 재학습 자동 활용 루프는 확인 근거 없음 |

---

## 3. 현재 확인된 핵심 문제

### 문제 1) scope/trace는 배포됐지만 hub 비-legacy ingest가 확인되지 않음
- 원인 후보
  - scope 런타임에서 hub ingest 분기 대신 forecaster ingest 분기 사용
  - 환경변수/이미지/런타임 분기 불일치
- 영향
  - 수집 경로가 legacy ingest 중심으로 동작하여 표준 경로(scope -> hub) 입증 불가
- 우선순위
  - 상

### 문제 2) `policy_decisions = 0`
- 원인 후보
  - Multi-LightGBM 정책 API 호출 경로 미사용
  - 모델 로드 실패 또는 fallback 고정
- 영향
  - 정책 후보 생성의 ML 기반 검증 불충분
- 우선순위
  - 상

### 문제 3) autoscaling 대상 워크로드 불일치
- 원인 후보
  - 정책 대상(`all-workloads`)이 실제 클러스터에 없음
  - workload kind/namespace 매핑 불일치
- 영향
  - 실행 단계에서 실패 로그 반복, 성공률 저하
- 우선순위
  - 상

### 문제 4) 결과 저장 후 재학습 활용 루프 근거 부족
- 원인 후보
  - hub -> forecaster 재학습 트리거 경로 문서/운영 스크립트 부재
- 영향
  - 시나리오2의 end-to-end 학습 폐루프 입증 불가
- 우선순위
  - 중

---

## 4. 수정 우선순위 및 단계별 개발 계획

### Step 1. 입력 수집 경로 복구
- 목표
  - `insight-scope/trace` 입력이 `insight-hub`의 non-legacy ingest로 기록되도록 복구
- 수정 대상 파일 / 컴포넌트
  - `insight-scope/deployments/insight-scope.yaml`
  - `insight-trace/deployments/insight-trace.yaml`
  - `year3-integration/1.setup/08.install-apollo-components.sh`
  - `insight-scope/pkg/client/forecaster_client.go` (분기 확인)
- 확인 방법
  - `kubectl get ds,deploy -n apollo`
  - scope 로그에서 hub 연결/submit 로그 확인
  - hub 로그에서 `STORED sqlite node=... ts_ms_range=...` 패턴 확인
- 완료 조건
  - scope/trace/hub 모두 Ready
  - hub non-legacy ingest 로그가 실제 발생

### Step 2. Multi-LightGBM 실제 호출 및 모델 로드 확인
- 목표
  - `policy_decisions` 카운터 증가 및 정책 API 결과 확인
- 수정 대상 파일 / 컴포넌트
  - `apollo/node-resource-forecaster/server/grpc_server.py`
  - `apollo/node-resource-forecaster/server/http_server.py`
  - `apollo/node-resource-forecaster/models/multi_lightgbm.py`
  - `apollo/deployments/node-resource-forecaster.yaml` (모델 경로/볼륨)
- 확인 방법
  - `/health`에서 `policy_decisions > 0`
  - `/api/v1/policy/<node>` 응답 검증
  - 모델 로드 로그(`Loaded LightGBM model ...`) 확인
- 완료 조건
  - 정책 후보 생성이 실제 API/로그로 입증됨

### Step 3. forecaster -> policy-engine 정책 예측 결과 반영 확인
- 목표
  - forecaster 응답이 OPE 정책 생성 필드에 반영됨을 입증
- 수정 대상 파일 / 컴포넌트
  - `apollo/orchestration-policy-engine/internal/forecaster/client.go`
  - `apollo/orchestration-policy-engine/internal/generator/policy_generator.go`
- 확인 방법
  - OPE 로그의 추천 반영 메시지 추적
  - 생성된 `OrchestrationPolicy`의 타입/확률/사유와 forecaster 응답 비교
- 완료 조건
  - forecaster 기반 정책 생성 연동 증거 확보

### Step 4. orchestrator autoscaling / migration / provisioning 실행 정합성 수정
- 목표
  - 실행 대상 매핑 오류 제거(`all-workloads` 불일치 해소)
- 수정 대상 파일 / 컴포넌트
  - `apollo/orchestration-policy-engine/internal/controller/orchestrationpolicy_controller.go`
  - `apollo/orchestration-policy-engine/internal/operator/client.go`
  - `ai-storage-orchestrator/pkg/controller/autoscaling.go`
  - `ai-storage-orchestrator/pkg/apis/handler.go`
- 확인 방법
  - orchestrator 로그 오류 감소 확인
  - 정책 실행 상태 `Completed` 비율 확인
- 완료 조건
  - autoscaling/migration/provisioning 각각 성공 사례 확보

### Step 5. 결과 저장 스키마 및 재학습 활용 구조 정리
- 목표
  - hub 저장 데이터가 예측/학습 루프로 재사용되는 운영 경로 명확화
- 수정 대상 파일 / 컴포넌트
  - `insight-hub/internal/store/sqlite.go`
  - `insight-hub/internal/grpc/server.go`
  - `apollo/node-resource-forecaster/server/hub_sync.py`
  - `year3-integration/README.md` 및 검증 스크립트
- 확인 방법
  - hub sync 로그, 학습 데이터 적재/모델 갱신 이벤트 확인
- 완료 조건
  - 저장 -> 활용 경로가 로그/문서/스크립트로 재현 가능

---

## 5. 최종 목표 상태

시나리오2 end-to-end 완료 기준:

1. 입력 수집 정상 (`insight-scope`/`insight-trace` -> `insight-hub` non-legacy ingest 확인)
2. LSTM 예측 정상 (`/forecast` 응답, 예측 카운터 증가)
3. LightGBM 정책 후보 생성 정상 (`policy_decisions` 증가, 정책 API 응답)
4. policy-engine이 예측 결과 기반 정책 생성 (CR/로그 일치)
5. orchestrator가 autoscaling / migration / provisioning 실행 성공
6. 결과가 hub에 저장되고 후속 학습 데이터로 활용 가능

---

## 즉시 수정해야 할 3가지

1. **Step 1 잔여 이슈 해결**
   - scope -> hub non-legacy ingest 로그가 나오도록 runtime 분기/배포 정합성 먼저 확정

2. **Multi-LightGBM 실동작 검증**
   - `policy_decisions=0` 원인 확인 및 모델 로드/호출 경로 점검

3. **오케스트레이터 대상 정합성 수정**
   - `all-workloads not found` 제거를 위한 정책 타깃 매핑 정리
