#!/usr/bin/env bash
# 99.demo-prereqs-teardown.sh 는 00.demo-prereqs-setup.sh 가 만든
# 데모 전제 자원을 한 번에 정리한다.
#
# 안전: --ignore-not-found 를 사용해 부분 적용된 상태도 깔끔히 정리.
# StorageClass / PriorityClass 는 클러스터 전역이라 가장 마지막에 삭제한다.
#
# Author: 미정
# Created: 2026-05-26
set -euo pipefail

echo "=== demo-prereqs teardown ==="

# 1) namespaced resources
kubectl delete --ignore-not-found -n demo-lb deploy/demo-lb-decoy
kubectl delete --ignore-not-found ns/demo-lb
kubectl delete --ignore-not-found -n ope-model-verify \
  deploy/demo-migration-workload \
  job/demo-cache-source-seed \
  job/demo-autoscale-loader \
  pod/demo-preemption-victim \
  pvc/demo-cache-source
# WHY: 데모 도중 만들어진 migrated- Pod 도 함께 정리한다(같은 namespace 만 대상).
kubectl delete --ignore-not-found -n ope-model-verify \
  pod -l migration.ai-storage/job=true

# 2) static PV pool (재바인딩 안전을 위해 PVC 정리 이후 삭제)
for i in 1 2 3 4 5; do
  kubectl delete --ignore-not-found "pv/demo-provisioning-pv-${i}"
done

# 3) cluster scoped (마지막)
kubectl delete --ignore-not-found sc/high-throughput
kubectl delete --ignore-not-found priorityclass/demo-low-priority

echo "=== demo-prereqs teardown done ==="
