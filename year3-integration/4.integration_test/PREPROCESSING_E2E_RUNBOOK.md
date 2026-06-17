# Preprocessing Pipeline End-to-End Integration Runbook

This runbook prepares scenario 1 and scenario 2 validation for the MataFS-ready preprocessing workflow.
It does not ask operators to change the test workflow and does not require separate remote/on-site commands.

## Scope

- Workflow manifest: `year3-integration/4.integration_test/manifests/preprocessing-pipeline-workflow.yaml`
- Workflow runner: `year3-integration/4.integration_test/scripts/run-preprocessing-pipeline.sh`
- Scenario 1 verifier: `year3-integration/4.integration_test/scripts/verify-preprocessing-pipeline.sh`
- Scenario 2 verifier: `year3-integration/4.integration_test/scripts/verify-preprocessing-orchestration.sh`

The workflow is still MataFS-ready, not MataFS-mounted. It uses `PREPROCESS_BASE_DIR=/work/preprocess`, Argo artifacts, and future MataFS paths under `/matafs/preprocess/{workflow_name}/...`.

## Scenario 1: Basic Execution and Storage Connection

Validation target:

1. Workflow can be created.
2. The AI Storage webhook mutates workflow Pods.
3. `insight-trace` sidecar is injected into each step Pod.
4. Each `main` container exits successfully.
5. `insight-trace` exits as `Completed` without `OOMKilled`.
6. preprocess, train, and evaluate artifacts are connected.
7. Fallback markers are absent:
   - `manifest not found`
   - `model artifact missing`
   - `fallback chunks`
   - `fallback model`
8. PVCs are created and attached to workflow Pods.
9. Capacity, performance, and metadata/random I/O storage roles map to the expected StorageClasses.
10. PVC StorageClass, capacity, access modes, bound PV, volumeMounts, and storage annotations are visible.

The integration workflow has three PVC templates:

- `preprocess-capacity-data`: capacity workload, expected `storage-capacity`.
- `training-performance-data`: performance training workload, expected `storage-performance`.
- `metadata-randomio-data`: metadata/random I/O workload, expected `storage-performance`.

## Scenario 2: Observability, Policy, and Orchestration

Validation target:

1. `insight-trace` emits workload trace/signature related logs from workflow sidecars.
2. APOLLO policy-server receives `WorkloadSignature` when that deployment exists.
3. `insight-scope` and `insight-hub` show resource history activity.
4. Insight Hub has `resource_snapshots` and `orchestration_results` tables.
5. `resource_snapshots` count increases after the workflow.
6. `node-resource-forecaster` logs forecast/policy/recommendation activity.
7. `orchestration-policy-engine` logs recommendation or policy execution activity.
8. `ai-storage-orchestrator` logs migration/provisioning/execution/result activity.
9. `orchestration_results` count increases after the workflow.

Current code-level verdict:

- Implemented: `insight-trace` sends workload signatures to APOLLO policy-server through gRPC `ReportWorkloadSignature`.
- Implemented: `insight-scope` can pull trace/signature from sidecar APIs for explicit analysis requests.
- Implemented: `insight-scope` submits resource history to `insight-hub`; `insight-hub` stores this in `resource_snapshots`.
- Implemented: `node-resource-forecaster` is configured to read history from `insight-hub`.
- Implemented: `orchestration-policy-engine` can request recommendations from `node-resource-forecaster`.
- Implemented: `ai-storage-orchestrator` can publish orchestration results to `insight-hub`.
- Partial: Hub currently exposes `resource_snapshots` and `orchestration_results`; a dedicated workload trace/signature persistence table was not found in the current code path.
- Partial: The automatic chain from a preprocessing workflow signature to forecaster, policy recommendation, orchestrator execution, and `orchestration_results` insertion depends on deployed policy triggers and workload conditions. The verifier treats missing activity in these stages as FAIL for end-to-end validation, not as an assumed success.

## Common Install

Use the same command flow for remote and on-site installation:

```bash
cd /root/workspace
INJECTION_NAMESPACE=default SCOPE_POD_SELECTOR='integration.keti.io/component=preprocessing-pipeline' bash year3-integration/1.setup/install-scenario1.sh
bash year3-integration/1.setup/install-scenario2.sh
```

Check the workflow CRD:

```bash
kubectl get crd workflows.argoproj.io
```

Check core services:

```bash
kubectl get pod -n keti
kubectl get pod -n apollo
kubectl get pod -n kube-system -l app=ai-storage-orchestrator
kubectl get storageclass
```

## Scenario 2 Baseline Before Workflow

Capture Insight Hub DB counts before running the workflow:

```bash
cd /root/workspace
NAMESPACE=default \
HUB_NAMESPACE=keti \
APOLLO_NAMESPACE=apollo \
ORCH_NAMESPACE=kube-system \
bash year3-integration/4.integration_test/scripts/verify-preprocessing-orchestration.sh --phase before
```

This writes `/tmp/preprocessing-orchestration-baseline.env` by default.

## Run Workflow

Submit the integration workflow:

```bash
cd /root/workspace
NAMESPACE=default bash year3-integration/4.integration_test/scripts/run-preprocessing-pipeline.sh
```

Capture the workflow name from the output, or list the latest workflow:

```bash
kubectl get wf -n default -l integration.keti.io/component=preprocessing-pipeline
```

Wait until the workflow completes:

```bash
kubectl get wf -n default
kubectl get pod -n default -l workflows.argoproj.io/workflow=<workflow-name>
```

## Scenario 1 Verification

Run the full workflow and storage verifier:

```bash
cd /root/workspace
NAMESPACE=default \
WORKFLOW_NAME=<workflow-name> \
bash year3-integration/4.integration_test/scripts/verify-preprocessing-pipeline.sh --mode all
```

Workflow-only verification:

```bash
NAMESPACE=default WORKFLOW_NAME=<workflow-name> \
bash year3-integration/4.integration_test/scripts/verify-preprocessing-pipeline.sh --mode workflow
```

Storage-only verification:

```bash
NAMESPACE=default WORKFLOW_NAME=<workflow-name> \
bash year3-integration/4.integration_test/scripts/verify-preprocessing-pipeline.sh --mode storage
```

Manual commands for scenario 1:

```bash
kubectl get wf -n default
kubectl get pod -n default -l workflows.argoproj.io/workflow=<workflow-name>
kubectl describe pod <pod> -n default
kubectl get pvc -n default
kubectl describe pvc <pvc> -n default
kubectl get pv
kubectl get storageclass
kubectl get pod <pod> -n default -o yaml
kubectl logs <pod> -n default -c main
kubectl logs <pod> -n default -c insight-trace
```

Scenario 1 PASS criteria:

- Workflow phase is `Succeeded`.
- All step Pods contain `main` and injected `insight-trace`.
- Pods show `schedulerName=ai-storage-scheduler` and `shareProcessNamespace=true`.
- `insight-trace` env contains `CONTAINER_NAME=main`.
- All `main` containers exit `0`.
- All `insight-trace` containers exit `0` with reason `Completed`.
- No container has `OOMKilled`.
- Required preprocessing, train, and evaluate markers appear in main logs.
- Forbidden fallback log markers do not appear.
- PVCs are `Bound`, have selected-tier annotations, and are attached to expected StorageClasses.
- Pod volumes and `main` volumeMounts show the tier paths.

## Scenario 2 Verification After Workflow

Allow at least one `insight-scope` flush interval if resource history has not appeared yet. The current scope default flush interval is five minutes.

```bash
cd /root/workspace
NAMESPACE=default \
WORKFLOW_NAME=<workflow-name> \
HUB_NAMESPACE=keti \
APOLLO_NAMESPACE=apollo \
ORCH_NAMESPACE=kube-system \
SINCE=30m \
bash year3-integration/4.integration_test/scripts/verify-preprocessing-orchestration.sh --phase after
```

Current-state check without before/after DB comparison:

```bash
NAMESPACE=default WORKFLOW_NAME=<workflow-name> \
bash year3-integration/4.integration_test/scripts/verify-preprocessing-orchestration.sh --phase check
```

Manual commands for scenario 2:

```bash
kubectl logs -n keti deploy/insight-hub --since=30m
kubectl logs -n keti daemonset/insight-scope --since=30m --all-containers=true
kubectl logs -n keti deploy/apollo-policy-server --since=30m
kubectl logs -n apollo deploy/node-resource-forecaster --since=30m
kubectl logs -n apollo deploy/orchestration-policy-engine --since=30m
kubectl logs -n kube-system deploy/ai-storage-orchestrator --since=30m
kubectl -n keti exec deploy/insight-hub -- sqlite3 /data/insight-hub.db ".tables"
kubectl -n keti exec deploy/insight-hub -- sqlite3 /data/insight-hub.db "select count(*) from resource_snapshots;"
kubectl -n keti exec deploy/insight-hub -- sqlite3 /data/insight-hub.db "select count(*) from orchestration_results;"
```

Scenario 2 PASS criteria:

- Required deployments or daemonsets are present and ready.
- Workflow sidecar logs contain signature/report activity.
- APOLLO policy-server logs show WorkloadSignature receive activity when the deployment exists.
- Scope or Hub logs show resource history submission/storage.
- Hub `resource_snapshots` count increases after workflow execution.
- Forecaster logs show forecast, predict, policy, or recommendation activity.
- Policy engine logs show recommendation, OrchestrationPolicy, or execution activity.
- Orchestrator logs show migration, provisioning, execution, success, failure, publish, or result activity.
- Hub `orchestration_results` count increases after workflow execution.

## Failure Stage Mapping

- `webhook/sidecar`: namespace label, webhook configuration, sidecar injection, scheduler mutation, `CONTAINER_NAME=main`, sidecar completion.
- `PVC/storage`: StorageClass, PVC, selected tier, PV binding, volumeMount mapping, storage hint annotations.
- `artifact 연결`: preprocess to train to evaluate artifact logs, missing artifact fallback markers.
- `trace/scope/hub`: trace sidecar logs, scope/hub resource history, hub table and count checks.
- `forecaster`: forecast, predict, or recommendation logs.
- `policy`: policy engine recommendation or execution logs.
- `orchestrator`: migration, provisioning, execution, or result publish logs.
- `hub result 저장`: `orchestration_results` table and before/after count increase.

## Remaining Integration Items

- Replace local `/work/preprocess` with real MataFS-backed path by changing `PREPROCESS_BASE_DIR`.
- Add real MataFS mount or CSI/PVC integration when available.
- Replace planned `gluesys_path_api` fields with real Gluesys API calls.
- Persist workload trace/signature records in Insight Hub if the final architecture requires Hub to own them.
- Define the trigger that turns preprocessing workflow signatures or Hub history into policy recommendations.
- Confirm whether `apollo-policy-server` is installed by scenario installers or should be added to the common install flow.
- Confirm orchestration policy auto-execution conditions for the preprocessing workflow.
