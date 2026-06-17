# AI-Storage 10.0.4.99 복구용 Export 패키지

이 패키지는 10.0.4.99에서 누락 또는 미동작으로 확인된 항목을 복구하기 위해 10.0.4.80에서 찾은 원본 CRD, Custom Resource, manifest, Helm values/manifest, 이미지 태그, scheduler plugin 소스를 모은 것입니다.

주의: 10.0.4.80 서버의 현재 실행 상태는 워커 노드 제거로 인해 정상 기준으로 판단하지 않았습니다. 기능 실행 테스트도 수행하지 않았고, 파일과 리소스 export만 수행했습니다.

## Export 위치

| 구분 | 경로 |
|---|---|
| 압축 파일 | `/root/ai-storage-export-for-99.tar.gz` |
| 압축 해제 디렉터리 | `/root/ai-storage-export-for-99/` |
| CRD | `/root/ai-storage-export-for-99/crds/` |
| Custom Resource | `/root/ai-storage-export-for-99/custom-resources/` |
| Deployment/Service/ConfigMap/RBAC/Webhook manifest | `/root/ai-storage-export-for-99/manifests/` |
| Helm values/manifest | `/root/ai-storage-export-for-99/helm/` |
| Scheduler plugin source | `/root/ai-storage-export-for-99/scheduler-source-if-found/` |
| 점검 결과와 이미지 태그 | `/root/ai-storage-export-for-99/checks/` |

## 복구 매핑 표

| 10.0.4.99 실패 항목 | 10.0.4.80에서 찾은 대응 파일 | export 경로 | 10.0.4.99 적용 순서 | 적용 명령어 | 확인 명령어 | 못 찾은 항목 |
|---|---|---|---:|---|---|---|
| workload가 `ai-storage-scheduler`가 아니라 `default-scheduler`로 배치됨 | scheduler manifest, webhook manifest, namespace label 목록 | `manifests/ai-storage-scheduler-related.yaml`, `manifests/ai-storage-webhook-related.yaml`, `manifests/mutatingwebhookconfiguration.yaml`, `checks/namespaces-labels.txt` | 3 | `kubectl apply -f manifests/ai-storage-scheduler-related.yaml && kubectl apply -f manifests/ai-storage-webhook-related.yaml && kubectl apply -f manifests/mutatingwebhookconfiguration.yaml` | `kubectl get mutatingwebhookconfiguration`; `kubectl get deploy,svc,cm -A | grep -Ei 'ai-storage-scheduler|ai-storage-webhook'`; `kubectl get ns --show-labels` | 없음 |
| scheduler Filter/Score/Bind 결과 UNKNOWN | scheduler manifest, scheduler plugin source, 관련 이미지 태그 | `manifests/ai-storage-scheduler-related.yaml`, `scheduler-source-if-found/root_workspace_ai-storage-scheduler/`, `checks/images-info/related-images.tsv` | 3 | `kubectl apply -f manifests/ai-storage-scheduler-related.yaml` | `kubectl -n keti get deploy,svc,cm | grep ai-storage-scheduler`; `kubectl -n keti get deploy ai-storage-scheduler -o yaml | grep image:` | 없음 |
| `aistorageconfigs` CRD 없음 | `aistorageconfigs.ai-storage.keti` CRD | `crds/aistorageconfigs.ai-storage.keti.yaml` | 1 | `kubectl apply -f crds/aistorageconfigs.ai-storage.keti.yaml` | `kubectl get crd aistorageconfigs.ai-storage.keti` | Custom Resource 인스턴스는 빈 목록 |
| `SchedulingPolicy` CRD 또는 리소스 없음 | 대응 CRD/CR 검색 수행 | `checks/not-found.txt`, `checks/errors.txt` | 해당 없음 | 해당 없음 | `kubectl get crd | grep -Ei 'schedulingpolic'`; `kubectl get schedulingpolicies -A` | `NOT_FOUND: schedulingpolicy CRD`, `NOT_FOUND: schedulingpolicies Custom Resource` |
| Kueue localqueue / clusterqueue / workload 없음 | Kueue CRD, localqueue, clusterqueue, resourceflavor, workload, Helm release | `crds/*kueue*.yaml`, `custom-resources/kueue-localqueues-all.yaml`, `custom-resources/kueue-clusterqueues.yaml`, `custom-resources/kueue-resourceflavors.yaml`, `custom-resources/kueue-workloads-all.yaml`, `helm/kueue-system-kueue-values.yaml`, `helm/kueue-system-kueue-manifest.yaml` | 1, 2, 4 | `kubectl apply -f crds/`; `kubectl apply -f helm/kueue-system-kueue-manifest.yaml`; `kubectl apply -f custom-resources/kueue-resourceflavors.yaml -f custom-resources/kueue-clusterqueues.yaml -f custom-resources/kueue-localqueues-all.yaml` | `kubectl get localqueue -A`; `kubectl get clusterqueue`; `kubectl get resourceflavor`; `kubectl get workload -A` | 없음 |
| Insight Hub / Scope / Trace 리소스 없음 | Insight 관련 deploy/svc/cm/sa/rbac, 이미지 태그 | `manifests/insight-hub-scope-trace-related.yaml`, `checks/images-info/related-images.tsv` | 3 | `kubectl apply -f manifests/insight-hub-scope-trace-related.yaml` | `kubectl get deploy,svc,pod,cm,sa -A | grep -Ei 'insight-hub|insight-scope|insight-trace|insight'` | 없음 |
| `OrchestrationPolicy` 인스턴스 없음 | OrchestrationPolicy CRD와 인스턴스 | `crds/orchestrationpolicies.apollo.keti.re.kr.yaml`, `custom-resources/orchestrationpolicies-all.yaml` | 1, 4 | `kubectl apply -f crds/orchestrationpolicies.apollo.keti.re.kr.yaml`; `kubectl apply -f custom-resources/orchestrationpolicies-all.yaml` | `kubectl get orchestrationpolicies -A` | 없음 |
| `selected_policy none` | policy engine, OrchestrationPolicy, scheduling-policy-engine 이미지 단서 | `manifests/orchestration-policy-engine-related.yaml`, `custom-resources/orchestrationpolicies-all.yaml`, `checks/images-info/related-images.tsv` | 3, 4 | `kubectl apply -f manifests/orchestration-policy-engine-related.yaml`; `kubectl apply -f custom-resources/orchestrationpolicies-all.yaml` | `kubectl get deploy,svc,cm -A | grep -Ei 'policy-engine|orchestration-policy-engine'`; `kubectl get orchestrationpolicies -A` | SchedulingPolicy CRD/CR은 NOT_FOUND |
| orchestrator apply not invoked | ai-storage-orchestrator deploy/svc/cm | `manifests/ai-storage-orchestrator-related.yaml` | 3 | `kubectl apply -f manifests/ai-storage-orchestrator-related.yaml` | `kubectl get deploy,svc,cm -A | grep -Ei 'ai-storage-orchestrator|orchestrator'` | 없음 |
| before/after 리소스 변화 없음 | orchestrator, policy engine, OrchestrationPolicy, Kueue CR | `manifests/ai-storage-orchestrator-related.yaml`, `manifests/orchestration-policy-engine-related.yaml`, `custom-resources/orchestrationpolicies-all.yaml`, `custom-resources/kueue-*.yaml` | 3, 4 | `kubectl apply -f manifests/ai-storage-orchestrator-related.yaml`; `kubectl apply -f manifests/orchestration-policy-engine-related.yaml`; `kubectl apply -f custom-resources/orchestrationpolicies-all.yaml` | `kubectl get orchestrationpolicies -A`; `kubectl get workload -A`; `kubectl get events -A --sort-by=.lastTimestamp` | 기능 실행 검증은 수행하지 않음 |
| Argo Application 없음 | Argo Application export | `custom-resources/argo-applications-all.yaml` | 4 | `kubectl apply -f custom-resources/argo-applications-all.yaml` | `kubectl get applications -A` | 없음 |
| Kubeflow Workflow 없음 | Kubeflow Workflow export, Kubeflow/MLflow Helm manifest | `custom-resources/kubeflow-workflows-all.yaml`, `custom-resources/kubeflow-workflow-all.yaml`, `helm/kubeflow-mlflow-values.yaml`, `helm/kubeflow-mlflow-manifest.yaml` | 2, 4 | `kubectl apply -f helm/kubeflow-mlflow-manifest.yaml`; `kubectl apply -f custom-resources/kubeflow-workflows-all.yaml`; `kubectl apply -f custom-resources/kubeflow-workflow-all.yaml` | `kubectl get workflows -A`; `kubectl get workflow -A`; `kubectl get pods -n kubeflow` | `NOT_FOUND: runs`, `NOT_FOUND: pipelineruns`; `experiments` 인스턴스는 빈 목록 |

## 권장 적용 순서

1. CRD 적용: `kubectl apply -f crds/`
2. Helm 원본 manifest 적용 또는 Helm chart 재설치: `helm/helm-list-all.txt`, `helm/*-values.yaml`, `helm/*-manifest.yaml` 확인
3. 핵심 컨트롤러와 주입 구성 적용: `manifests/ai-storage-scheduler-related.yaml`, `manifests/ai-storage-webhook-related.yaml`, `manifests/mutatingwebhookconfiguration.yaml`, `manifests/ai-storage-orchestrator-related.yaml`, `manifests/orchestration-policy-engine-related.yaml`, `manifests/insight-hub-scope-trace-related.yaml`
4. Custom Resource 적용: `custom-resources/` 아래 Kueue, OrchestrationPolicy, Argo, Kubeflow 리소스
5. 이미지 태그 확인: `checks/images-info/related-images.tsv`
6. namespace label 조건 확인: `checks/namespaces-labels.txt`

## 주요 이미지 태그

전체 이미지 목록은 `checks/images-info/all-pod-images.tsv`, 관련 이미지 목록은 `checks/images-info/related-images.tsv`에 저장했습니다.

대표 항목:

| 구성요소 | 이미지 |
|---|---|
| ai-storage-scheduler | `keti-ai-storage-scheduler:fallback-v2` |
| ai-storage-webhook | `ketidevit2/ai-storage-webhook:storageclass-rechange` |
| ai-storage-orchestrator | `ai-storage-orchestrator:demo-paramsv3` |
| orchestration-policy-engine | `docker.io/ketidevit2/orchestration-policy-engine:demo-paramsv1` |
| scheduling-policy-engine | `docker.io/library/scheduling-policy-engine:latest` |
| insight-hub | `insight-hub:latest` |
| insight-scope | `docker.io/ketidevit2/insight-scope@sha256:d3c0a8218fce8a8ffdb677d6168ef509f6a63cd4edf756415f41f9b3c8775906` |
| insight-trace | `ketidevit2/insight-trace:latest`, `ketidevit2/insight-trace:job-exit-20260527` |
| Kueue | `registry.k8s.io/kueue/kueue:v0.14.4` |

## Scheduler 소스

Scheduler plugin 후보는 `checks/scheduler-plugin-path-candidates.txt`에 기록했습니다. 최종 export에는 원본 workspace에서 찾은 다음 경로를 포함했습니다.

`scheduler-source-if-found/root_workspace_ai-storage-scheduler/`

확인된 plugin 파일 예시는 `azuredisklimits.go`, `balancedallocation.go`, `csistorageaware.go`, `datalocalityaware.go`, `defaultbinder.go`, `defaultpreemption.go`, `ebslimits.go`, `gcepdlimits.go`, `imagelocality.go`, `interpodaffinity.go`, `iopatternbased.go`, `kueueaware.go`, `leastallocated.go`, `nodeaffinity.go`, `nodename.go`, `nodeports.go`, `noderesourcesfit.go`, `nodeunschedulable.go`, `nodevolumelimits.go`, `pipelinestageaware.go`, `podtopologyspread.go`, `shardaware.go`, `storagetieraware.go`, `tainttoleration.go`, `volumebinding.go`, `volumerestrictions.go`, `volumezone.go`, `cachelocality/score.go`입니다.

## NOT_FOUND

`checks/not-found.txt`에 원본을 함께 저장했습니다.

| 항목 | 상태 |
|---|---|
| SchedulingPolicy CRD | `NOT_FOUND` |
| schedulingpolicies Custom Resource | `NOT_FOUND` |
| Kubeflow runs | `NOT_FOUND` |
| PipelineRuns | `NOT_FOUND` |
| aistorageconfigs Custom Resource 인스턴스 | `NOT_FOUND: CRD는 있으나 items: []` |
| Kubeflow experiments 인스턴스 | `NOT_FOUND: 리소스 타입은 있으나 items: []` |

## 생성 명령

이 패키지는 다음 기준으로 생성했습니다.

```bash
bash /root/workspace/export_for_99.sh
tar -czf /root/ai-storage-export-for-99.tar.gz -C /root ai-storage-export-for-99
```
