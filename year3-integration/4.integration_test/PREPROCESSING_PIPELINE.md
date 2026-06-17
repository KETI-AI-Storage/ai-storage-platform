# Preprocessing Pipeline Integration Procedure

This document prepares the MataFS-ready preprocessing workflow for the year3 integration flow.
It does not mount MataFS, create PVCs, use hostPath, or call Gluesys APIs yet.

## Files

- Manifest: `year3-integration/4.integration_test/manifests/preprocessing-pipeline-workflow.yaml`
- Run script: `year3-integration/4.integration_test/scripts/run-preprocessing-pipeline.sh`
- Scenario 1 verify script: `year3-integration/4.integration_test/scripts/verify-preprocessing-pipeline.sh`
- Scenario 2 verify script: `year3-integration/4.integration_test/scripts/verify-preprocessing-orchestration.sh`
- End-to-end runbook: `year3-integration/4.integration_test/PREPROCESSING_E2E_RUNBOOK.md`

## Install

Use the existing scenario installers first. These commands are the same for remote and on-site installation.

```bash
cd /root/workspace
INJECTION_NAMESPACE=default bash year3-integration/1.setup/install-scenario1.sh
bash year3-integration/1.setup/install-scenario2.sh
```

Argo Workflows must already be installed in the cluster. The run script checks for the `workflows.argoproj.io` CRD before submitting the workflow.

## Run

Submit the preprocessing workflow:

```bash
cd /root/workspace
NAMESPACE=default bash year3-integration/4.integration_test/scripts/run-preprocessing-pipeline.sh
```

The script prints and executes:

```bash
kubectl create -n default -f /root/workspace/year3-integration/4.integration_test/manifests/preprocessing-pipeline-workflow.yaml -o name
```

To use a different namespace:

```bash
NAMESPACE=<namespace> bash year3-integration/4.integration_test/scripts/run-preprocessing-pipeline.sh
```

## Verify

Verify the latest preprocessing workflow in the namespace:

```bash
cd /root/workspace
NAMESPACE=default bash year3-integration/4.integration_test/scripts/verify-preprocessing-pipeline.sh
```

Or verify a specific workflow:

```bash
NAMESPACE=default WORKFLOW_NAME=<workflow-name> bash year3-integration/4.integration_test/scripts/verify-preprocessing-pipeline.sh
```

The verification script checks:

- Workflow status and progress
- Pod status
- webhook mutation and injected `insight-trace` sidecars
- preprocess, train, and evaluate main logs
- `insight-trace` sidecar termination status
- absence of fallback markers
- required preprocessing log markers
- train shard and count logs
- evaluate placement-plan logs
- PVC, StorageClass, PV binding, storage annotations, and Pod volumeMount mapping

For scenario 2 observability, policy, and orchestration checks:

```bash
NAMESPACE=default bash year3-integration/4.integration_test/scripts/verify-preprocessing-orchestration.sh --phase before
NAMESPACE=default WORKFLOW_NAME=<workflow-name> bash year3-integration/4.integration_test/scripts/verify-preprocessing-orchestration.sh --phase after
```

## Expected Artifacts

The workflow uses `PREPROCESS_BASE_DIR=/work/preprocess` and creates:

- `input/raw/samples.jsonl`
- `input/chunks/chunk-0001.jsonl`
- `input/chunks/chunk-0002.jsonl`
- `input/shards/shard-0001.tar`
- `input/shards/shard-0002.tar`
- `stages/{decode,filter,transform,package}/_SUCCESS`
- `stages/{decode,filter,transform,package}/stage-summary.json`
- `index/metadata-index.json`
- `manifest.json`
- `output/placement-plan.json`
- `output/cleanup-plan.json`
- `model/model.json`
- `reports/evaluation-report.json`

The metadata includes future MataFS paths under `/matafs/preprocess/{workflow_name}/...`.

## Remaining MataFS and Gluesys Work

- Add the real MataFS mount or CSI/PVC integration.
- Change `PREPROCESS_BASE_DIR` to the actual MataFS-backed base path.
- Replace planned `gluesys_path_api` metadata fields with real Gluesys API calls.
- Map `target_worker` values to real worker identity and placement decisions.
- Connect cleanup-plan execution to the sidecar or a controller.
