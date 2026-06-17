# 고효율 AI Storage 통합 시연 Runbook (Argo 미사용)

> 본 문서는 책임자 시연용 실행 절차서입니다. Argo Workflow / Argo Server / Kubeflow UI는
> 일절 호출하지 않으며, 모든 검증은 raw Kubernetes 리소스(Deployment, PVC, Pod,
> OrchestrationPolicy CR)와 컴포넌트 API/로그를 기준으로 합니다.
>
> 본 시연 스크립트는 워크로드 이름 / PVC 이름 / app label / namespace / 정책 값을
> 스크립트 안에 박지 않습니다. 모든 값은 다음 우선순위로 결정합니다.
>
> 1. 사용자가 스크립트 뒤에 넘긴 **positional argument**
> 2. `4.integration_test/scripts/demo/.runtime/<scenario>.env` 의 runtime state
> 3. `4.integration_test/manifests/*.yaml` 의 매니페스트 파싱 결과
> 4. `kubectl` 로 라벨(`workload.keti.io/type=preprocessing,workload.keti.io/stage=preprocess`)을 조회한 결과
>
> 위 4가지 중 어느 것으로도 단일 후보가 잡히지 않으면 스크립트는 **임의 기본값을 만들지 않고**
> `ERROR: ... 값을 단일 후보로 특정할 수 없습니다. ...` 메시지를 출력하고 즉시 중단합니다.

---

## 1. 시연 목적

- 고효율 통합 검증 결과를 책임자에게 "동작 화면"으로 시연한다.
- 이미 개발된 컴포넌트(ai-storage-webhook, ai-storage-scheduler, storage-burst,
  node-resource-forecaster, orchestration-policy-engine, ai-storage-orchestrator)가
  실제로 동작하는지 raw Kubernetes 명령으로 검증한다.
- 검증은 항상 `kubectl` / `jsonpath` / 컴포넌트 API / Pod 로그 결과로 판정한다.
  `echo` 만으로 성공으로 위장하지 않는다.

## 2. 디렉터리 구조

```text
scripts/demo/
├── common.sh                 # 출력/시간 측정 공통 유틸 (PASS/WARN/FAIL 카운터 포함, 변경 없음)
├── runtime.sh                # 본 작업으로 추가된 라이브러리: state I/O + 워크로드/매니페스트 자동 탐색 + die
├── run-demo-all.sh           # Scenario 1 -> Scenario 2 -> cleanup
├── run-scenario1.sh          # scenario1/01..05 순차 실행
├── run-scenario2.sh          # scenario2/01..06 순차 실행
├── scenario1/
│   ├── 01.preprocessing-workload.sh
│   ├── 02.ai-storage-webhook.sh
│   ├── 03.storage-pvc-binding.sh
│   ├── 04.ai-storage-scheduler.sh
│   └── 05.preprocessing-result.sh
├── scenario2/
│   ├── 01.node-resource-forecaster.sh
│   ├── 02.policy-recommendation.sh
│   ├── 03.orchestration-policy-engine.sh
│   ├── 04.ai-storage-orchestrator.sh
│   ├── 05.orchestration-policy.sh
│   └── 06.autoscaling-change.sh
└── .runtime/                 # 자동 생성. 시연 도중 단계간 상태 공유에 사용
    ├── scenario1.env
    ├── scenario2.env
    ├── api/                  # forecast / recommendation 응답 JSON 저장
    └── snapshots/            # 오토스케일링 전후 스냅샷
```

## 3. Runtime state 파일 스펙

각 시나리오는 다음 키를 source 가능한 `KEY="value"` 형식으로 `.runtime/<scenario>.env` 에 저장한다.

| Key | 의미 | 채워지는 시점 |
|---|---|---|
| `SCENARIO_NAME`     | `scenario1` 또는 `scenario2` | 01번이 처음 실행될 때 |
| `MANIFEST_PATH`     | 매니페스트 절대 경로 | 01번이 매니페스트 결정 후 |
| `NAMESPACE`         | 워크로드를 배포한 namespace | 01번이 결정 후 |
| `WORKLOAD_KIND`     | 매니페스트의 Deployment 등 kind | 01번이 매니페스트 파싱 후 |
| `WORKLOAD_NAME`     | Deployment `metadata.name` | 01번이 매니페스트 파싱 후 |
| `APP_LABEL_KEY`     | Deployment selector의 키 (e.g. `app`) | 01번이 매니페스트/Deployment 조회 후 |
| `APP_LABEL_VALUE`   | Deployment selector의 값 | 01번이 매니페스트/Deployment 조회 후 |
| `PVC_NAMES`         | 매니페스트가 만든 PVC 이름(콤마구분) | 01번이 매니페스트 파싱 후 |
| `POD_SELECTOR`      | `${APP_LABEL_KEY}=${APP_LABEL_VALUE}` | 01번이 결정 후 |
| `POLICY_ID`         | 오케스트레이터가 부여한 autoscaler/migration id | scenario2/05번 실행 후 |
| `POLICY_NAME`       | OrchestrationPolicy CR 이름(scenario2) 또는 추천 정책 타입(scenario2/02 단계 임시) | scenario2/02번, scenario2/05번 |
| `REQUEST_ID`        | API 응답의 `request_id` 또는 Deployment uid | 01번 또는 scenario2/01번 |
| `TRACE_ID`          | API 응답의 `trace_id` 또는 Deployment creationTimestamp | 01번 또는 scenario2/05번 |
| `API_RESPONSE_FILE` | forecast / recommendation 응답이 저장된 파일 경로 | scenario2/01, scenario2/02번 |
| `LAST_UPDATED_AT`   | 마지막 갱신 시각(ISO8601) | `state_put` 호출 시 자동 |

값이 비어 있는 상태로 후속 단계가 그 값을 읽으면 후속 단계가 `die_missing`으로 중단된다.

## 4. 워크로드/네임스페이스/정책 결정 우선순위 (스크립트 공통)

각 스크립트는 다음 순서로 값을 결정한다. 어떤 단계로도 값이 단일 후보로 잡히지 않으면 임의 기본값을
만들지 않고 즉시 에러로 중단한다.

1. **사용자 positional argument**
   - 01번: `[manifest_path_or_workload_name] [namespace]`
   - 02~05번 (scenario1), 01~04번 (scenario2): `[workload_name] [namespace]`
   - scenario2/05번: `[policy_type] [resource_type] [horizon]`
   - scenario2/06번: `<before|after|compare>` (필수)
2. **runtime state 파일** — scenario2의 02~06번은 우선 `scenario2.env`, 없으면 `scenario1.env`
3. **매니페스트 파싱** — `manifests/*.yaml` 중에서 라벨(`workload.keti.io/type=preprocessing,workload.keti.io/stage=preprocess`)을
   가진 Deployment를 찾는다. 정확히 1개일 때만 채택.
4. **클러스터 라벨 조회** — `kubectl get deploy -A -l <label>` 결과가 정확히 1개일 때만 채택.
5. **에러 종료** — 단일 후보로 좁히지 못하면 `ERROR: <KEY> 값을 단일 후보로 특정할 수 없습니다. ...` 출력 후 종료.

`namespace`는 위 4번 직전에 `keti-ai-storage-injection=enabled` 라벨을 가진 namespace 1개로 자동 결정될
수 있다(`discover_namespace`).

## 5. 정책값 결정 — EXECUTE_POLICY 등 정해진 플래그 없음

scenario2/05번(`05.orchestration-policy.sh`)은 다음 순서로 정책 값을 결정한다.

1. positional argument — `bash 05.orchestration-policy.sh <policy_type> <resource_type> <horizon>`
2. `.runtime/scenario2.env` 의 `POLICY_NAME`(=정책 타입), `POLICY_RESOURCE`, `POLICY_HORIZON`
   - 이 값들은 02번(`02.policy-recommendation.sh`)이 policy-engine 로그의 recommendation dump를
     파싱한 결과로 채운다.
3. 위 두 곳 모두에서 값이 없으면 `ERROR: POLICY_TYPE 값을 단일 후보로 특정할 수 없습니다.`
   메시지로 즉시 중단한다.

OrchestrationPolicy CR의 `metadata.name`은 runtime에 `demo-<unix-ts>-<random>` 형태로 생성되며,
정해진 이름을 박지 않는다. 실행 후 `POLICY_NAME=<CR 이름>`, `POLICY_ID=<orchestrator id>` 가
state에 저장된다.

## 6. Scenario 1 실행 방법

```bash
# (A) 매니페스트 경로를 직접 지정
bash year3-integration/4.integration_test/scripts/demo/run-scenario1.sh \
  year3-integration/4.integration_test/manifests/<your-manifest.yaml>

# (B) 매니페스트의 워크로드 이름만 지정 (이름이 manifests/ 안에서 유일해야 함)
bash year3-integration/4.integration_test/scripts/demo/run-scenario1.sh <workload-name>

# (C) 인자 없이 자동 결정
#  - manifests/ 안에서 라벨 workload.keti.io/type=preprocessing,workload.keti.io/stage=preprocess 매니페스트가
#    정확히 1개일 때만 자동 채택
bash year3-integration/4.integration_test/scripts/demo/run-scenario1.sh
```

`namespace`는 `keti-ai-storage-injection=enabled` 라벨이 1개 namespace에만 붙어 있으면 자동 결정된다.
2개 이상이거나 라벨이 없으면 두 번째 인자로 namespace를 지정해야 한다.

```bash
bash year3-integration/4.integration_test/scripts/demo/run-scenario1.sh <manifest_or_name> <namespace>
```

## 7. Scenario 1 성공 기준

각 단계 스크립트가 마지막 라인에 `상태=정상`을 출력해야 PASS로 판정된다. `상태=비정상`이 한 단계라도
나오면 `run-scenario1.sh` 의 종합 결과는 `RESULT=FAIL`이다.

- 01: 매니페스트 파싱 + `kubectl apply` 성공
- 02: `schedulerName=ai-storage-scheduler`, `shareProcessNamespace=true`, `insight-trace` sidecar 주입,
  `sidecar.CONTAINER_NAME == main_container`
- 03: PVC `phase=Bound`, PV `phase=Bound`, Pod volume이 PVC를 참조, PVC volume의 mountPath 존재
- 04: Pod `spec.nodeName` 채워짐, `PodScheduled=True`
- 05: preprocess 컨테이너 로그에 `main complete`, chunk/manifest 파일이 컨테이너 내부에 존재

## 8. Scenario 2 실행 방법

```bash
# Scenario 1을 먼저 실행해 .runtime/scenario1.env가 채워져 있어야 한다.
bash year3-integration/4.integration_test/scripts/demo/run-scenario2.sh

# 또는 워크로드 이름을 명시
bash year3-integration/4.integration_test/scripts/demo/run-scenario2.sh <workload-name>

# 정책 타입을 강제 지정하고 싶다면 05번 단독 호출
bash year3-integration/4.integration_test/scripts/demo/scenario2/05.orchestration-policy.sh \
  <policy_type> <resource_type> <horizon>
```

`run-scenario2.sh` 의 내부 실행 순서:

1. `01.node-resource-forecaster.sh` — 컨텍스트 확정 + forecast API 응답 저장
2. `02.policy-recommendation.sh` — recommendation dump 파싱 + `POLICY_NAME/RESOURCE/HORIZON` state 저장
3. `03.orchestration-policy-engine.sh` — policy-engine 상태/로그
4. `04.ai-storage-orchestrator.sh` — orchestrator `/health`
5. `06.autoscaling-change.sh before` — 변경 전 스냅샷
6. `05.orchestration-policy.sh` — state의 추천값으로 OrchestrationPolicy CR 실행
7. `06.autoscaling-change.sh after` — 변경 후 스냅샷(20초 대기)
8. `06.autoscaling-change.sh compare` — before/after 비교

## 9. 개별 스크립트 단독 실행

전체 흐름을 돌리지 않고 한 단계만 점검하려면 디렉터리에서 직접 호출한다.

```bash
# scenario1
bash year3-integration/4.integration_test/scripts/demo/scenario1/02.ai-storage-webhook.sh
bash year3-integration/4.integration_test/scripts/demo/scenario1/03.storage-pvc-binding.sh
bash year3-integration/4.integration_test/scripts/demo/scenario1/04.ai-storage-scheduler.sh
bash year3-integration/4.integration_test/scripts/demo/scenario1/05.preprocessing-result.sh

# scenario2
bash year3-integration/4.integration_test/scripts/demo/scenario2/01.node-resource-forecaster.sh
bash year3-integration/4.integration_test/scripts/demo/scenario2/02.policy-recommendation.sh
bash year3-integration/4.integration_test/scripts/demo/scenario2/03.orchestration-policy-engine.sh
bash year3-integration/4.integration_test/scripts/demo/scenario2/04.ai-storage-orchestrator.sh
bash year3-integration/4.integration_test/scripts/demo/scenario2/06.autoscaling-change.sh before
bash year3-integration/4.integration_test/scripts/demo/scenario2/05.orchestration-policy.sh
bash year3-integration/4.integration_test/scripts/demo/scenario2/06.autoscaling-change.sh after
bash year3-integration/4.integration_test/scripts/demo/scenario2/06.autoscaling-change.sh compare
```

01번을 건너뛰고 02 이후를 실행하면 state 파일이 없으므로 다음과 같이 에러로 중단된다.

```text
ERROR: WORKLOAD_NAME/NAMESPACE 값을 단일 후보로 특정할 수 없습니다.
01번을 먼저 실행하거나 인자로 지정하세요.
```

## 10. 출력 원칙

- 모든 단계의 출력은 박스 타이틀로 시작하고 `key=value` 중심으로 사람이 읽기 쉽게 정리한다.
- PASS/WARN/FAIL 카운트는 단계별 출력에 노출하지 않고, `run-scenario1.sh` / `run-scenario2.sh`
  종합 라인에만 표기한다(`정상=… 기타=… 비정상=…` + `RESULT=PASS|FAIL`).
- raw JSON / payload 원문 / 매니페스트 본문은 표시하지 않는다.
- `kubectl get pods -A`, `kubectl get all -A`, `kubectl describe node` 전체 출력, 클러스터 덤프는
  어디서도 호출하지 않는다.

## 11. cleanup 정책

`run-demo-all.sh` 가 EXIT trap에서 단 1회 실행한다.

- **Deployment 삭제**: `kubectl delete deploy ${WORKLOAD_NAME} -n ${NAMESPACE} --ignore-not-found`
  (이름/네임스페이스는 `.runtime/scenario1.env`에서 읽는다)
- **PVC 보존**: `kubectl delete pvc` 명령은 어떤 경로로도 호출하지 않는다.
- **OrchestrationPolicy 정리**: label selector
  `generated-by=demo-scenario2,target-workload=${WORKLOAD_NAME}` 만 삭제.

## 12. 시연자 체크리스트

- [ ] 시연 전: `keti-ai-storage-injection=enabled` 라벨이 단일 namespace에 있는지 확인하거나, 두 번째
      인자로 namespace를 지정할 준비
- [ ] `manifests/` 안에 라벨이 일치하는 매니페스트가 정확히 1개이거나, 첫 번째 인자로 명시할 준비
- [ ] `bash run-demo-all.sh ...` 실행 후 종합 라인 `RESULT=PASS` 확인
- [ ] `.runtime/scenario1.env` 와 `.runtime/scenario2.env` 가 갱신되어 있는지 확인
- [ ] cleanup 메시지에 `PVC preserved: ...` 가 출력되는지 확인 (PVC는 반드시 살아 있어야 함)
