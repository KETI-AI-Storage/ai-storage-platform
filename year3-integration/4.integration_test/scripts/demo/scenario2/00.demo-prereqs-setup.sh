#!/usr/bin/env bash
# 00.demo-prereqs-setup.sh 는 6 개 정책이 실제 K8s 리소스 변화를 만들도록
# 데모 전제 자원을 한 번에 띄운다.
#
# 멱등 보장: 모든 명령에 --dry-run 분기 또는 || true 를 두지 않고,
# kubectl apply 의 declarative 특성에 의존한다.
# 환경변수로 시연 환경에 맞춰 노드를 바꿀 수 있다.
#
# Env:
#   DEMO_PREEMPT_NODE     preemption 후보 Pod 이 떠야 할 노드(default: gpu-server-03)
#   DEMO_LB_BIASED_NODE   loadbalance decoy 가 몰리는 노드(default: gpu-server-03)
#
# Author: 미정
# Created: 2026-05-26
# Related: year3-integration/4.integration_test/manifests/demo-prereqs/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$(cd "${SCRIPT_DIR}/../../../manifests/demo-prereqs" && pwd)"
TMP_DIR="$(mktemp -d -t demo-prereqs.XXXXXX)"
# WHY: 실패해도 임시 디렉터리는 남기지 않는다.
trap 'rm -rf "${TMP_DIR}"' EXIT

DEMO_PREEMPT_NODE="${DEMO_PREEMPT_NODE:-gpu-server-03}"
DEMO_LB_BIASED_NODE="${DEMO_LB_BIASED_NODE:-gpu-server-03}"
# WHY: migration 전용 Pod 은 _시연 워크로드와 같은 노드_ 에 박혀 있을 때
#      Apollo 가 alternate node 를 자동 선택해 다른 노드로 옮기는 것이 검증된다.
DEMO_MIGRATION_SOURCE_NODE="${DEMO_MIGRATION_SOURCE_NODE:-gpu-server-03}"

echo "=== demo-prereqs setup ==="
echo "manifest_dir=${MANIFEST_DIR}"
echo "preempt_node=${DEMO_PREEMPT_NODE}"
echo "lb_biased_node=${DEMO_LB_BIASED_NODE}"
echo "migration_source_node=${DEMO_MIGRATION_SOURCE_NODE}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

# WHY: nodeName 이 박힌 manifest 2 종은 환경마다 노드명이 달라 sed 로 치환해 임시 적용한다.
render_node_yaml() {
  local src="${1}" dst="${2}" node="${3}"
  sed -e "s|nodeName: gpu-server-03|nodeName: ${node}|g" "${src}" > "${dst}"
}

apply_or_die() {
  local file="${1}"
  echo "+ kubectl apply -f ${file}"
  kubectl apply -f "${file}"
}

# 1) StorageClass + static PV pool (provisioning + caching 공용)
apply_or_die "${MANIFEST_DIR}/00-storageclass-demo-provisioning.yaml"

# 2) caching source PVC + seed Job
apply_or_die "${MANIFEST_DIR}/01-caching-source-pvc.yaml"
echo "+ waiting demo-cache-source PVC to be Bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/demo-cache-source -n ope-model-verify --timeout=120s
echo "+ waiting demo-cache-source-seed.seed container to terminate (exit 0)..."
# WHY: 클러스터에 sidecar inject webhook(insight-trace) 가 동작하면 Job Pod 이 1/2 NotReady
#      상태로 남아 condition=complete 가 안 잡힌다. 우리에게 필요한 건 seed 컨테이너의 exit 0
#      이므로 컨테이너 단위 종료 코드를 polling 으로 확인한다.
seed_wait_deadline=$(( $(date +%s) + 120 ))
seed_done=false
while [[ "$(date +%s)" -lt "${seed_wait_deadline}" ]]; do
  seed_pod="$(kubectl -n ope-model-verify get pod -l job-name=demo-cache-source-seed -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${seed_pod}" ]]; then
    seed_exit="$(kubectl -n ope-model-verify get pod "${seed_pod}" -o jsonpath='{.status.containerStatuses[?(@.name=="seed")].state.terminated.exitCode}' 2>/dev/null || true)"
    if [[ "${seed_exit}" == "0" ]]; then
      seed_done=true
      echo "+ demo-cache-source-seed.seed terminated exitCode=0"
      break
    fi
  fi
  sleep 3
done
[[ "${seed_done}" == "true" ]] || echo "WARN: seed container did not terminate within 120s (will continue)"

# 3) preemption PriorityClass + victim Pod (노드명 치환)
render_node_yaml \
  "${MANIFEST_DIR}/02-preemption-priorityclass-and-pod.yaml" \
  "${TMP_DIR}/02-preemption-priorityclass-and-pod.rendered.yaml" \
  "${DEMO_PREEMPT_NODE}"
apply_or_die "${TMP_DIR}/02-preemption-priorityclass-and-pod.rendered.yaml"
echo "+ waiting demo-preemption-victim Pod to be Running..."
kubectl wait --for=condition=Ready --timeout=120s \
  pod/demo-preemption-victim -n ope-model-verify || \
  echo "WARN: demo-preemption-victim not ready (계속 진행)"

# 4) loadbalance decoy Deployment (노드명 치환)
render_node_yaml \
  "${MANIFEST_DIR}/03-loadbalance-decoy-pods.yaml" \
  "${TMP_DIR}/03-loadbalance-decoy-pods.rendered.yaml" \
  "${DEMO_LB_BIASED_NODE}"
apply_or_die "${TMP_DIR}/03-loadbalance-decoy-pods.rendered.yaml"
echo "+ waiting demo-lb-decoy Deployment to be Available..."
kubectl rollout status deployment/demo-lb-decoy -n demo-lb --timeout=180s || true

# 5) autoscaling 보조 부하 Job (옵션)
apply_or_die "${MANIFEST_DIR}/04-autoscaling-load-generator.yaml"

# 6) migration 전용 PVC-less Deployment (노드명 치환)
render_node_yaml \
  "${MANIFEST_DIR}/05-migration-workload.yaml" \
  "${TMP_DIR}/05-migration-workload.rendered.yaml" \
  "${DEMO_MIGRATION_SOURCE_NODE}"
apply_or_die "${TMP_DIR}/05-migration-workload.rendered.yaml"
echo "+ waiting demo-migration-workload Deployment to be Available..."
kubectl -n ope-model-verify rollout status deploy/demo-migration-workload --timeout=180s || \
  echo "WARN: demo-migration-workload not ready (계속 진행)"

echo
echo "=== demo-prereqs setup done ==="
kubectl get sc high-throughput -o wide || true
kubectl get pv -l demo.keti.io/component=provisioning || true
kubectl get pvc -n ope-model-verify demo-cache-source || true
kubectl get pod -n ope-model-verify -l demo.keti.io/component=preemption -o wide || true
kubectl get pod -n ope-model-verify -l app=demo-migration-workload -o wide || true
kubectl get pod -n demo-lb -l app=demo-lb-decoy -o wide | head -5 || true
