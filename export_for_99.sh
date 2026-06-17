#!/usr/bin/env bash
set -u

OUT="/root/ai-storage-export-for-99"
CRDS="$OUT/crds"
CR="$OUT/custom-resources"
MAN="$OUT/manifests"
HELM="$OUT/helm"
SRC="$OUT/scheduler-source-if-found"
CHK="$OUT/checks"
IMG="$CHK/images-info"
NF="$CHK/not-found.txt"
ERR="$CHK/errors.txt"
SUMMARY="$CHK/export-summary.tsv"

mkdir -p "$CRDS" "$CR" "$MAN" "$HELM" "$SRC" "$CHK" "$IMG"
: > "$NF"
: > "$ERR"
: > "$SUMMARY"

record_found() {
  printf '%s\t%s\n' "$1" "$2" >> "$SUMMARY"
}

record_missing() {
  printf '%s\n' "$1" >> "$NF"
}

save_resource() {
  local label="$1"
  local file="$2"
  shift 2
  if "$@" > "$file" 2>>"$ERR"; then
    if grep -Eq '^(No resources found|Error from server|error:)' "$file"; then
      record_missing "$label"
      rm -f "$file"
    else
      record_found "$label" "$file"
    fi
  else
    record_missing "$label"
    rm -f "$file"
  fi
}

save_crd_by_pattern() {
  local label="$1"
  local pattern="$2"
  local matched=0
  kubectl get crd -o name 2>>"$ERR" | grep -Ei "$pattern" | while read -r crd_name; do
    [ -n "$crd_name" ] || continue
    matched=1
    local plain="${crd_name#customresourcedefinition.apiextensions.k8s.io/}"
    save_resource "$label/$plain" "$CRDS/$plain.yaml" kubectl get "$crd_name" -o yaml
  done
  if ! kubectl get crd -o name 2>>"$ERR" | grep -Eiq "$pattern"; then
    record_missing "$label CRD"
  fi
}

save_kind_all_namespaces() {
  local label="$1"
  local kind="$2"
  local file="$3"
  save_resource "$label" "$file" kubectl get "$kind" -A -o yaml
}

save_kind_cluster() {
  local label="$1"
  local kind="$2"
  local file="$3"
  save_resource "$label" "$file" kubectl get "$kind" -o yaml
}

save_named_matches() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  local tmp="$CHK/${label//[^A-Za-z0-9_.-]/_}-matches.txt"
  kubectl get deploy,svc,cm,sa,role,rolebinding -A 2>>"$ERR" | grep -Ei "$pattern" > "$tmp" || true
  if [ ! -s "$tmp" ]; then
    record_missing "$label"
    return
  fi
  : > "$file"
  while read -r ns type_name _rest; do
    [ -n "$ns" ] && [ -n "$type_name" ] || continue
    {
      echo "---"
      kubectl -n "$ns" get "$type_name" -o yaml 2>>"$ERR"
    } >> "$file"
  done < "$tmp"
  record_found "$label" "$file"
}

kubectl get crd > "$CHK/crd-list.txt" 2>>"$ERR" && record_found "전체 CRD 목록" "$CHK/crd-list.txt" || record_missing "전체 CRD 목록"
kubectl get crd | grep -Ei 'aistorage|scheduling|orchestration|apollo|keti|kueue|workload|localqueue|clusterqueue' > "$CHK/related-crd-list.txt" 2>>"$ERR" || true

save_crd_by_pattern "aistorageconfigs" 'aistorageconfigs|aistorage'
save_crd_by_pattern "schedulingpolicy" 'schedulingpolic'
save_crd_by_pattern "orchestrationpolicy" 'orchestrationpolic'
save_crd_by_pattern "kueue" 'kueue|localqueue|clusterqueue|resourceflavor|workload'
save_crd_by_pattern "ai-storage-apollo-keti" 'ai-storage|aistorage|apollo|keti'

save_kind_all_namespaces "aistorageconfigs Custom Resource" "aistorageconfigs" "$CR/aistorageconfigs-all.yaml"
save_kind_all_namespaces "schedulingpolicies Custom Resource" "schedulingpolicies" "$CR/schedulingpolicies-all.yaml"
save_kind_all_namespaces "orchestrationpolicies Custom Resource" "orchestrationpolicies" "$CR/orchestrationpolicies-all.yaml"
save_kind_all_namespaces "Kueue localqueues" "localqueues" "$CR/kueue-localqueues-all.yaml"
save_kind_cluster "Kueue clusterqueues" "clusterqueues" "$CR/kueue-clusterqueues.yaml"
save_kind_cluster "Kueue resourceflavors" "resourceflavors" "$CR/kueue-resourceflavors.yaml"
save_kind_all_namespaces "Kueue workloads" "workloads" "$CR/kueue-workloads-all.yaml"

save_named_matches "Insight Hub Scope Trace" 'insight-hub|insight-scope|insight-trace|insight' "$MAN/insight-hub-scope-trace-related.yaml"
save_resource "MutatingWebhookConfiguration" "$MAN/mutatingwebhookconfiguration.yaml" kubectl get mutatingwebhookconfiguration -o yaml
save_named_matches "ai-storage-webhook" 'ai-storage-webhook|aistorage-webhook|storage.*webhook' "$MAN/ai-storage-webhook-related.yaml"
save_named_matches "ai-storage-scheduler" 'ai-storage-scheduler|aistorage-scheduler' "$MAN/ai-storage-scheduler-related.yaml"
save_named_matches "ai-storage-orchestrator" 'ai-storage-orchestrator|aistorage-orchestrator|orchestrator' "$MAN/ai-storage-orchestrator-related.yaml"
save_named_matches "orchestration-policy-engine" 'orchestration-policy-engine|policy-engine' "$MAN/orchestration-policy-engine-related.yaml"

save_kind_all_namespaces "Argo Applications" "applications" "$CR/argo-applications-all.yaml"
save_kind_all_namespaces "Kubeflow workflows" "workflows" "$CR/kubeflow-workflows-all.yaml"
save_kind_all_namespaces "Kubeflow workflow" "workflow" "$CR/kubeflow-workflow-all.yaml"
save_kind_all_namespaces "Kubeflow experiments" "experiments" "$CR/kubeflow-experiments-all.yaml"
save_kind_all_namespaces "Kubeflow runs" "runs" "$CR/kubeflow-runs-all.yaml"
save_kind_all_namespaces "PipelineRuns" "pipelineruns" "$CR/pipelineruns-all.yaml"

kubectl get ns --show-labels > "$CHK/namespaces-labels.txt" 2>>"$ERR" && record_found "namespace labels" "$CHK/namespaces-labels.txt" || record_missing "namespace labels"
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' > "$IMG/all-pod-images.tsv" 2>>"$ERR" && record_found "전체 Pod 이미지 태그" "$IMG/all-pod-images.tsv" || record_missing "전체 Pod 이미지 태그"
grep -Ei 'ai-storage|aistorage|scheduler|webhook|orchestrator|policy-engine|insight|kueue|apollo|keti|kubeflow|argo' "$IMG/all-pod-images.tsv" > "$IMG/related-images.tsv" 2>/dev/null || record_missing "관련 이미지 태그"

find /root /workspace /home -path '*ai-storage-scheduelr/internal/framework/plugin*' -o -path '*ai-storage-scheduler/internal/framework/plugin*' -o -path '*internal/framework/plugin*' 2>/dev/null > "$CHK/scheduler-plugin-path-candidates.txt" || true
if [ -s "$CHK/scheduler-plugin-path-candidates.txt" ]; then
  while read -r path; do
    [ -e "$path" ] || continue
    case "$path" in
      */internal/framework/plugin*)
        base="${path%%/internal/framework/plugin*}"
        safe="$(echo "$base" | sed 's#^/##; s#[/ ]#_#g')"
        mkdir -p "$SRC/$safe"
        if [ -d "$base/internal/framework/plugin" ]; then
          cp -a "$base/internal/framework/plugin" "$SRC/$safe/" 2>>"$ERR" || true
        fi
        if [ -d "$base/internal/framework" ]; then
          cp -a "$base/internal/framework" "$SRC/$safe/internal-framework" 2>>"$ERR" || true
        fi
        ;;
    esac
  done < "$CHK/scheduler-plugin-path-candidates.txt"
  record_found "scheduler plugin source candidates" "$CHK/scheduler-plugin-path-candidates.txt"
else
  record_missing "scheduler 27 plugin source or registry/config"
fi

if command -v helm >/dev/null 2>&1; then
  helm list -A > "$HELM/helm-list-all.txt" 2>>"$ERR" && record_found "Helm release 목록" "$HELM/helm-list-all.txt" || record_missing "Helm release 목록"
  if [ -s "$HELM/helm-list-all.txt" ]; then
    awk 'NR>1 {print $1 "\t" $2}' "$HELM/helm-list-all.txt" | grep -Ei 'ai-storage|aistorage|apollo|keti|kueue|insight|argo|kubeflow|scheduler|orchestration|mlflow' | while IFS="$(printf '\t')" read -r rel ns; do
      [ -n "$rel" ] && [ -n "$ns" ] || continue
      safe="$(echo "${ns}-${rel}" | sed 's#[/ ]#-#g')"
      save_resource "helm values $ns/$rel" "$HELM/${safe}-values.yaml" helm get values "$rel" -n "$ns" -o yaml
      save_resource "helm manifest $ns/$rel" "$HELM/${safe}-manifest.yaml" helm get manifest "$rel" -n "$ns"
    done
  fi
else
  record_missing "helm binary"
fi
