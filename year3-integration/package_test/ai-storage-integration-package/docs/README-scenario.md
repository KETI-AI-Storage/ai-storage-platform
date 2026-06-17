# Scenario 스크립트 안내

본 패키지의 `scripts/` 아래에는 고효율 서버에서 검증한 두 가지 시나리오를 그대로 재현하기 위한 스크립트가 포함되어 있다.

## scenario1 — 전처리 파이프라인 + webhook + PVC tier 결정

| 순서 | 스크립트 | 목적 |
|---|---|---|
| 01 | `scenario1/01.preprocessing-workload.sh` | 전처리 워크로드 deployment apply |
| 02 | `scenario1/02.ai-storage-webhook.sh` | Pod 에 schedulerName / sidecar 주입 확인 |
| 03 | `scenario1/03.storage-pvc-binding.sh` | PVC 에 storageClassName / selected-tier 주입 확인 |
| 04 | `scenario1/04.ai-storage-scheduler.sh` | 스케줄러가 노드 선택 후 Pod 배치하는지 확인 |
| 05 | `scenario1/05.preprocessing-result.sh` | 전처리 결과 파일 / 로그 검증 |

`./scripts/run-scenario1.sh` 가 위 다섯 단계를 순서대로 실행한다.

## scenario2 — node forecasting → policy → orchestration migration

| 순서 | 스크립트 | 목적 |
|---|---|---|
| 00 | `scenario2/00.demo-prereqs-setup.sh` | 시나리오 prereq 리소스 prepare |
| 06 | `scenario2/06.node-resource-forecaster.sh` | 노드 자원 forecasting 결과 확인 |
| 07 | `scenario2/07.policy-recommendation.sh` | 정책 추천 결과 확인 |
| 08 | `scenario2/08.orchestration-policy-engine.sh` | policy engine 동작 점검 |
| 09 | `scenario2/09.ai-storage-orchestrator.sh` | orchestrator 헬스 점검 |
| 10 | `scenario2/10.orchestration-policy.sh` | orchestrator API 로 migration trigger |
| 11 | `scenario2/11.orchestration-compare.sh` | 원본 vs 최적화 Pod 자원 비교 |
| 99 | `scenario2/99.demo-prereqs-teardown.sh` | prereq teardown |

`./scripts/run-scenario2.sh` 가 위 단계를 순서대로 실행한다.

## 공통 사항

- 두 시나리오 모두 `scripts/common.sh`, `scripts/runtime.sh` 에 정의된 helper 와 환경 변수를 사용한다.
- 시나리오 스크립트는 `TARGET_NAMESPACE` (기본 `ai-storage-workloads`) 와 `WEBHOOK_NAMESPACE` (기본 `keti`) 환경변수를 따른다.
- 본 패키지에는 과거 실행 로그 (`.runtime/logs/*.log`) 와 snapshot 을 의도적으로 포함하지 않았다. 새 클러스터에서 처음부터 다시 실행하면 자체적으로 logs 디렉터리가 생성된다.
- demo prereq 매니페스트 (`manifests/demo-prereqs/*.yaml`) 는 namespace 가 검증용 `ope-model-verify` 로 유지되어 있는 상태라 본 패키지에는 포함하지 않았다. 필요 시 scenario1/2 스크립트가 호출하는 외부 매니페스트를 기관 운영 namespace 에 맞춰 별도로 제공한다.
- 일부 scenario 스크립트는 `apollo`, `insight-hub` 등 외부 서비스를 가정한다. 해당 서비스가 없는 환경에서는 단계 일부가 skip 또는 warn 으로 끝날 수 있다.

## 실행 명령 요약

```bash
./scripts/run-scenario1.sh
./scripts/run-scenario2.sh
./scripts/run-demo-all.sh

TARGET_NAMESPACE=my-ns WEBHOOK_NAMESPACE=keti ./scripts/run-scenario1.sh
```
