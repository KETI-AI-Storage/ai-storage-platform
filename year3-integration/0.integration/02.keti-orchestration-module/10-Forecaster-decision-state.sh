#!/usr/bin/env bash
# 10-Forecaster-decision-state.sh는 KETI 오케스트레이션 단계 [10] Forecaster Decision State 상태를 Kubernetes 결과로 출력한다.
#
# Author: 미정 <unknown@example.com>
# Created: 2026-05-28

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log-utils.sh"
init_step_context "10" "Decision Pipeline" "${1:-}" "${2:-}"
print_step_intent \
  "Forecaster API 기반 의사결정 입력 확인" \
  "이번 실행에서 호출한 LSTM / LightGBM 예측과 후보 정책 confidence 근거 확인" \
  "deploy/service/log/API/node-resource-forecaster" \
  "kubectl get deploy,svc,pod; kubectl exec forecaster API" \
  "current forecast and policy candidate evidence"

comp_ns="$(find_resource_namespace node-resource-forecaster)"
fc_pod="$([ -n "${comp_ns}" ] && kubectl get pod -n "${comp_ns}" -l app=node-resource-forecaster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fc_phase="$([ -n "${comp_ns}" ] && kubectl get pod -n "${comp_ns}" -l app=node-resource-forecaster -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
fc_ready="$([ -n "${comp_ns}" ] && kubectl get pod -n "${comp_ns}" -l app=node-resource-forecaster -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)"
fc_logs="$([ -n "${comp_ns}" ] && [ -n "${fc_pod}" ] && kubectl logs -n "${comp_ns}" "${fc_pod}" --tail=800 2>/dev/null || true)"
fc_svc="$([ -n "${comp_ns}" ] && kubectl get svc -n "${comp_ns}" node-resource-forecaster -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
fc_port="$([ -n "${comp_ns}" ] && [ -n "${fc_svc}" ] && kubectl get svc "${fc_svc}" -n "${comp_ns}" -o jsonpath='{.spec.ports[?(@.port==8080)].port}' 2>/dev/null || true)"
[ -z "${fc_port}" ] && fc_port="8080"
pod="$(find_workload_pod "${STEP_WORKLOAD}" "${STEP_NAMESPACE}")"
workload_node="$([ -n "${pod}" ] && [ -n "${STEP_NAMESPACE}" ] && kubectl get pod "${pod}" -n "${STEP_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
[ -z "${workload_node}" ] && workload_node="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{print $1; exit}')"
[ -z "${workload_node}" ] && workload_node="$(kubectl get nodes --no-headers 2>/dev/null | awk 'NR==1 {print $1}')"

print_kv "namespace_source" "$([ -n "${comp_ns}" ] && echo 'runtime-discovery' || echo 'SKIP_NOT_FOUND')"
print_kv "namespace_detected" "${comp_ns:-SKIP_NOT_FOUND}"
print_kv "forecaster" "$([ -n "${comp_ns}" ] && echo '✓ running' || echo '⚠ SKIP_NOT_FOUND')"
print_kv "pod" "${fc_pod:-SKIP_NOT_FOUND}"
print_kv "pod_phase" "${fc_phase:-UNKNOWN}"
print_kv "ready" "${fc_ready:-false}"
print_kv "forecast_node" "${workload_node:-UNKNOWN}"

api_status="000"; api_body=""; api_url=""; api_error=""; health_body=""; api_size="0"
api_file="${LOG_DIR}/forecaster-api-10.json"
probe_file="${LOG_DIR}/forecaster-probe-10.txt"
: > "${api_file}"

if [ -n "${comp_ns}" ] && [ -n "${fc_pod}" ] && [ "${fc_phase:-}" = "Running" ] && [ -n "${workload_node}" ]; then
  probe_out="$(kubectl exec -i -n "${comp_ns}" "${fc_pod}" -- python3 - "${workload_node}" "${fc_port}" <<'PYEOF' 2>/dev/null || true
import sys, urllib.request, urllib.error
node = sys.argv[1]
port = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "8080"
base = "http://127.0.0.1:%s" % port
def get(path):
    try:
        r = urllib.request.urlopen(base + path, timeout=8)
        return r.status, r.read().decode("utf-8", "replace"), ""
    except urllib.error.HTTPError as e:
        return e.code, "", "HTTP %d" % e.code
    except Exception as e:
        return 0, "", "%s: %s" % (type(e).__name__, e)
hs, hb, he = get("/health")
print("HEALTH_BODY=%s" % hb.replace("\n", " ").strip())
for p in ["/api/v1/forecast/node/%s?horizons=15,30,60,120" % node, "/api/v1/forecast/node/%s" % node, "/api/v1/forecast/%s" % node]:
    s, b, e = get(p)
    if s == 200 and b.strip():
        print("URL=%s%s" % (base, p)); print("STATUS=%d" % s); print("SIZE=%d" % len(b)); print("ERROR="); print("BODY_START"); sys.stdout.write(b); sys.exit(0)
print("URL=%s%s" % (base, p)); print("STATUS=%d" % s); print("SIZE=%d" % len(b)); print("ERROR=%s" % e); print("BODY_START"); sys.stdout.write(b)
PYEOF
)"
  printf '%s\n' "${probe_out}" > "${probe_file}"
  health_body="$(printf '%s\n' "${probe_out}" | sed -n 's/^HEALTH_BODY=//p' | head -1)"
  api_url="$(printf '%s\n' "${probe_out}" | sed -n 's/^URL=//p' | head -1)"
  api_status="$(printf '%s\n' "${probe_out}" | sed -n 's/^STATUS=//p' | head -1)"
  api_size="$(printf '%s\n' "${probe_out}" | sed -n 's/^SIZE=//p' | head -1)"
  api_error="$(printf '%s\n' "${probe_out}" | sed -n 's/^ERROR=//p' | head -1)"
  api_body="$(printf '%s\n' "${probe_out}" | sed -n '/^BODY_START$/,$p' | sed '1d')"
else
  api_error="forecaster pod not running or workload node missing"
fi
printf '%s' "${api_body}" > "${api_file}"
[ "${api_size:-0}" = "0" ] && api_size="$(printf '%s' "${api_body}" | wc -c | tr -d ' ')"

model_lstm="$(printf '%s %s' "${health_body}" "${fc_logs}" | grep -qi 'lstm' && echo '✓ model evidence observed' || echo '⚠ model evidence missing')"
model_lightgbm="$(printf '%s %s' "${health_body}" "${fc_logs}" | grep -qi 'lightgbm' && echo '✓ model evidence observed' || echo '⚠ model evidence missing')"
print_commands_block "command" \
  "kubectl get deploy,svc,pod,pvc -A | grep node-resource-forecaster" \
  "kubectl logs -n ${comp_ns:-<ns>} ${fc_pod:-<pod>} --tail=800 | grep -Ei 'LSTM|LightGBM|forecast|prediction|confidence'" \
  "kubectl exec -n ${comp_ns:-<ns>} ${fc_pod:-<pod>} -- GET ${api_url:-<forecast-api>}"
print_kv "model_lstm" "${model_lstm}"
print_kv "model_lightgbm" "${model_lightgbm}"
[ -n "${health_body}" ] && print_kv "health" "${health_body}"
print_kv "api_url" "${api_url:-not-called}"
print_kv "api_status" "${api_status:-000}"
print_kv "api_response_file" "${api_file#${MODULE_DIR}/}"

parsed=""
candidate_rows=""
if [ "${api_status}" = "200" ] && command -v python3 >/dev/null 2>&1; then
  parsed="$(python3 - "${api_file}" <<'PYEOF' 2>/dev/null || true
import json, sys
def pct(v):
    try: return "{:.1f}%".format(float(v) * 100)
    except Exception: return "<n/a>"
def conf(v):
    try: return "{:.4f}".format(float(v))
    except Exception: return "<n/a>"
try:
    data=json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
fs=data.get("forecasts") or data.get("data") or []
if isinstance(fs, dict): fs=list(fs.values())
print("CONFIDENCE=" + conf(data.get("confidence")))
for h in (15,30,60,120):
    rec={}
    for item in fs:
        if not isinstance(item, dict): continue
        hv=item.get("horizon_minutes", item.get("horizon", item.get("minutes")))
        try:
            if int(str(hv).rstrip("m")) == h: rec=item; break
        except Exception: pass
    print("ROW={}m {} {} {} {}".format(h, pct(rec.get("predicted_cpu_utilization", rec.get("cpu"))), pct(rec.get("predicted_gpu_utilization", rec.get("gpu"))), pct(rec.get("predicted_memory_utilization", rec.get("memory"))), pct(rec.get("predicted_storage_io_utilization", rec.get("storage_io")))))
PYEOF
)"
  candidate_rows="$(python3 - "${api_file}" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)

def score(v):
    try:
        return "%.4f" % float(v)
    except Exception:
        return ""

containers = []
for key in ("candidates", "policy_candidates", "candidate_scores", "policy_scores", "scores", "recommendations", "actions"):
    value = data.get(key)
    if value:
        containers.append(value)

rows = []
for value in containers:
    if isinstance(value, dict):
        for name, item in value.items():
            if isinstance(item, dict):
                rows.append((name, score(item.get("confidence", item.get("score", item.get("probability")))), item.get("selected", False)))
            else:
                rows.append((name, score(item), False))
    elif isinstance(value, list):
        for item in value:
            if not isinstance(item, dict):
                continue
            name = item.get("policy", item.get("policy_type", item.get("action", item.get("name", ""))))
            rows.append((name, score(item.get("confidence", item.get("score", item.get("probability")))), item.get("selected", False)))

seen = set()
for name, value, selected in rows:
    if not name or not value or name in seen:
        continue
    seen.add(name)
    suffix = " selected" if str(selected).lower() == "true" else ""
    print("%-14s : %s%s" % (name, value, suffix))
PYEOF
)"
fi
confidence="$(printf '%s\n' "${parsed}" | awk -F= '$1=="CONFIDENCE" {print $2; exit}')"
forecast_table="$(printf 'horizon CPU GPU Memory StorageIO\n'; printf '%s\n' "${parsed}" | awk -F= '$1=="ROW" {print $2}')"
if [ "${api_status}" = "200" ] && printf '%s\n' "${forecast_table}" | grep -qE '^15m|^30m|^60m|^120m'; then
  print_kv "current_forecast" "✓ observed / source=api"
  print_ascii_table_block "forecast" "${forecast_table}"
  if [ -n "${candidate_rows}" ]; then
    print_raw_block "forecaster_candidates" "${candidate_rows}"
  else
    print_kv_warn "forecaster_candidates" "⚠ candidate scores unavailable in API response"
  fi
  print_kv "selected_policy" "policy selection pending"
  print_kv "selected_confidence" "${confidence:-<n/a>}"
  print_kv "forecast_source" "api"
  print_kv "result" "✓ forecast observed"
  save_state forecaster "✓ forecast observed / source=api / confidence=${confidence:-<n/a>}"
  save_state current_forecast "✓ observed / source=api"
  save_state selected_confidence "${confidence:-<n/a>}"
  save_state forecaster_candidates "$([ -n "${candidate_rows}" ] && echo observed || echo 'candidate scores unavailable in API response')"
else
  missing_inputs=""
  [ -z "${comp_ns}" ] && missing_inputs="${missing_inputs} deployment_namespace"
  [ -z "${fc_pod}" ] && missing_inputs="${missing_inputs} forecaster_pod"
  [ "${fc_phase:-}" != "Running" ] && missing_inputs="${missing_inputs} running_pod"
  [ -z "${workload_node}" ] && missing_inputs="${missing_inputs} workload_node"
  [ "${api_status:-000}" != "200" ] && missing_inputs="${missing_inputs} api_200_response"
  [ "${api_size:-0}" = "0" ] && missing_inputs="${missing_inputs} non_empty_response"
  print_kv_warn "forecast" "⚠ forecast value missing"
  print_kv_warn "current_forecast" "⚠ forecast value missing"
  print_kv_warn "forecaster_candidates" "⚠ candidate scores unavailable in API response"
  print_kv_warn "missing_input" "${missing_inputs:-forecast fields in API response}"
  print_kv_warn "api_error" "${api_error:-forecast fields not found}"
  print_kv "response_size" "${api_size:-0}"
  save_state forecaster "⚠ forecast value missing / missing_input=${missing_inputs:-forecast_fields}"
  save_state current_forecast "⚠ forecast value missing / missing_input=${missing_inputs:-forecast_fields}"
  save_state forecaster_candidates "candidate scores unavailable in API response"
fi
finish_step "10"
