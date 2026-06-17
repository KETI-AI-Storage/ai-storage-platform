#!/usr/bin/env bash
set -u

OUT="/root/ai-storage-export"
CRDS="$OUT/crds"
RES="$OUT/resources"
HELM="$OUT/helm"
SRC="$OUT/scheduler-source-if-found"
IMG="$OUT/images-info"
CHK="$OUT/checks"
NF="$CHK/not-found.txt"
ERR="$CHK/errors.txt"

mkdir -p "$CRDS" "$RES" "$HELM" "$SRC" "$IMG" "$CHK"
: > "$NF"
: > "$ERR"

run_save() {
  local label="$1"
  local file="$2"
  shift 2
  if "$@" > "$file" 2>>"$ERR"; then
    if grep -Eq '^(No resources found|Error from server|error:)' "$file"; then
      echo "$label" >> "$NF"
    fi
  else
    echo "$label" >> "$NF"
    rm -f "$file"
  fi
}

run_optional() {
  local label="$1"
  local file="$2"
  shift 2
  if ! "$@" > "$file" 2>>"$ERR"; then
    echo "$label" >> "$NF"
    rm -f "$file"
  fi
}

kubectl get crd > "$CHK/crd-list.txt" 2>>"$ERR" || echo "crd-list" >> "$NF"
kubectl get crd | grep -Ei 'aistorage|scheduling|orchestration|apollo|keti|kueue|workload|localqueue|clusterqueue' > "$CHK/related-crd-list.txt" 2>>"$ERR" || true

if [ -s "$CHK/related-crd-list.txt" ]; then
  awk 'NR>1 {print $1}' "$CHK/related-crd-list.txt" | while read -r crd; do
    [ -n "$crd" ] || continue
    run_optional "crd/$crd" "$CRDS/$crd.yaml" kubectl get crd "$crd" -o yaml
  done
fi

for resource in \
  aistorageconfigs \
  schedulingpolicies \
  orchestrationpolicies \
  localqueues \
  clusterqueues \
  workloads \
  resourceflavors \
  workloadclasses \
  applications \
  workflows \
  workflow \
  experiments \
  runs \
  pipelineruns; do
  run_save "$resource" "$RES/${resource}-all.yaml" kubectl get "$resource" -A -o yaml
done

run_optional "keti/deploy-ai-storage-scheduler" "$RES/keti-deploy-ai-storage-scheduler.yaml" kubectl -n keti get deploy ai-storage-scheduler -o yaml
run_optional "keti/all-configmaps" "$RES/keti-configmaps.yaml" kubectl -n keti get cm -o yaml
run_optional "keti/ai-storage-webhook" "$RES/keti-ai-storage-webhook-deploy-svc-cm.yaml" kubectl -n keti get deploy,svc,cm ai-storage-webhook -o yaml
run_optional "mutatingwebhookconfiguration" "$RES/mutatingwebhookconfiguration.yaml" kubectl get mutatingwebhookconfiguration -o yaml
run_optional "namespaces-labels" "$CHK/namespaces-labels.txt" kubectl get ns --show-labels

run_optional "kueue-system/resources" "$RES/kueue-system-all-cm-sa-role-rolebinding.yaml" kubectl -n kueue-system get all,cm,sa,role,rolebinding -o yaml

kubectl get deploy,svc,pod,cm,sa -A > "$CHK/all-deploy-svc-pod-cm-sa.txt" 2>>"$ERR" || echo "all-deploy-svc-pod-cm-sa" >> "$NF"
grep -Ei 'insight-hub|insight-scope|insight-trace|insight' "$CHK/all-deploy-svc-pod-cm-sa.txt" > "$CHK/insight-resources-found.txt" 2>/dev/null || echo "insight resources" >> "$NF"
if [ -s "$CHK/insight-resources-found.txt" ]; then
  awk 'NR>0 {print $1}' "$CHK/insight-resources-found.txt" | sort -u | while read -r ns; do
    [ -n "$ns" ] || continue
    run_optional "insight/$ns" "$RES/insight-${ns}-all-cm-sa-role-rolebinding.yaml" kubectl get all,cm,sa,role,rolebinding -n "$ns" -o yaml
  done
fi

run_optional "apollo/orchestration-policy-engine" "$RES/apollo-orchestration-policy-engine-deploy-svc-cm.yaml" kubectl -n apollo get deploy,svc,cm orchestration-policy-engine -o yaml
run_optional "kube-system/ai-storage-orchestrator" "$RES/kube-system-ai-storage-orchestrator-deploy-svc-cm.yaml" kubectl -n kube-system get deploy,svc,cm ai-storage-orchestrator -o yaml

run_optional "scheduler logs" "$CHK/ai-storage-scheduler-logs-filtered.txt" bash -c "kubectl -n keti logs deploy/ai-storage-scheduler --tail=5000 2>>'$ERR' | grep -Ei 'Plugin registered|Filter Plugin|Score Plugin|Bind|score|filter'"
grep -Ei 'Plugin registered' "$CHK/ai-storage-scheduler-logs-filtered.txt" > "$CHK/scheduler-plugin-registered.txt" 2>/dev/null || echo "scheduler plugin registered logs" >> "$NF"

if [ -f "$RES/keti-deploy-ai-storage-scheduler.yaml" ]; then
  grep -E 'image:' "$RES/keti-deploy-ai-storage-scheduler.yaml" > "$IMG/ai-storage-scheduler-images.txt" || true
fi
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' > "$IMG/all-pod-images.tsv" 2>>"$ERR" || echo "all pod images" >> "$NF"

find /root /workspace /home -path '*internal/framework/plugin*' -o -name '*.go' 2>/dev/null | grep -Ei 'scheduler|plugin|framework' > "$CHK/scheduler-source-candidates.txt" || echo "scheduler source candidates" >> "$NF"
if [ -s "$CHK/scheduler-source-candidates.txt" ]; then
  while read -r p; do
    [ -e "$p" ] || continue
    case "$p" in
      */internal/framework/plugin/*)
        base="${p%%/internal/framework/plugin/*}"
        dest="$SRC/$(echo "$base" | sed 's#^/##; s#[/ ]#_#g')"
        mkdir -p "$dest"
        cp -a "$base/internal" "$dest/" 2>>"$ERR" || true
        ;;
    esac
  done < "$CHK/scheduler-source-candidates.txt"
fi

if command -v helm >/dev/null 2>&1; then
  helm list -A > "$HELM/helm-list-all.txt" 2>>"$ERR" || echo "helm list" >> "$NF"
  if [ -s "$HELM/helm-list-all.txt" ]; then
    awk 'NR>1 {print $1 "\t" $2}' "$HELM/helm-list-all.txt" | grep -Ei 'ai-storage|apollo|keti|kueue|insight|argo|kubeflow|scheduler|orchestration' | while IFS="$(printf '\t')" read -r rel ns; do
      [ -n "$rel" ] && [ -n "$ns" ] || continue
      safe="$(echo "${ns}-${rel}" | sed 's#[/ ]#-#g')"
      helm get values "$rel" -n "$ns" -o yaml > "$HELM/${safe}-values.yaml" 2>>"$ERR" || echo "helm values $ns/$rel" >> "$NF"
      helm get manifest "$rel" -n "$ns" > "$HELM/${safe}-manifest.yaml" 2>>"$ERR" || echo "helm manifest $ns/$rel" >> "$NF"
    done
  fi
else
  echo "helm binary" >> "$NF"
fi
