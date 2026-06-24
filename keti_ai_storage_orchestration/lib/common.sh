#!/usr/bin/env bash
# common.sh — shared helpers for the demo package. Source me: source "<pkg>/lib/common.sh"

# pause_if LABEL — demo step gate. With PAUSE=1 and on a TTY, wait for Enter before continuing
# (lets a presenter explain each functional stage). No-op when PAUSE!=1 or non-interactive (CI).
pause_if() {
  [ "${PAUSE:-0}" = "1" ] || return 0
  [ -t 0 ] || return 0
  printf '\n  ⏸  [PAUSE] %s — press Enter to continue...' "${1:-next stage}"
  read -r _ || true
  echo
}

# detect_target_node — echo a good worker node for the load-based harnesses: exclude
# control-plane (label AND taint), require Ready + schedulable, pick the LARGEST allocatable
# CPU (most headroom, naturally avoids small master-ish nodes). Portable — no hardcoded name.
detect_target_node() {
  kubectl get nodes -o json 2>/dev/null | python3 -c '
import json,sys
def cpum(c):
    c=str(c or "0"); return int(c[:-1]) if c.endswith("m") else int(float(c)*1000)
best="";bc=-1
for n in json.load(sys.stdin).get("items",[]):
    m=n.get("metadata",{});sp=n.get("spec",{});st=n.get("status",{})
    if sp.get("unschedulable"): continue
    lb=m.get("labels",{}) or {}
    if "node-role.kubernetes.io/control-plane" in lb or "node-role.kubernetes.io/master" in lb: continue
    if any(str(t.get("key","")).startswith(("node-role.kubernetes.io/control-plane","node-role.kubernetes.io/master")) for t in (sp.get("taints") or [])): continue
    if {c.get("type"):c.get("status") for c in (st.get("conditions") or [])}.get("Ready")!="True": continue
    cpu=cpum((st.get("allocatable",{}) or {}).get("cpu"))
    if cpu>bc: bc=cpu; best=m.get("name","")
print(best)'
}

# detect_changed_workload — echo the deploy/<dir> WORKLOAD whose manifest or code YOU changed in the
# monorepo (uncommitted first, else the latest commit). No flag/argument. Matches a changed file under
# the workload's sourceDir (code, build:true) OR its deploy/<dir> (manifest — build:false alike), so it
# finds build:false workloads too. Empty output if no workload changed. Uses env MONOREPO.
detect_changed_workload() {
  local mono="${MONOREPO:-/tmp/ai-storage-platform}" files cfg dir src pat
  files=$(git -C "$mono" status --porcelain 2>/dev/null | awk '{print $NF}')
  [ -z "$files" ] && files=$(git -C "$mono" show --name-only --pretty=format: HEAD 2>/dev/null)
  [ -z "$files" ] && return 0
  for cfg in "$mono"/deploy/*/appconfig.json; do
    [ -f "$cfg" ] || continue
    dir=$(basename "$(dirname "$cfg")")
    src=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sourceDir") or "")' "$cfg" 2>/dev/null)
    pat="^deploy/${dir}/"
    [ -n "$src" ] && pat="^(deploy/${dir}/|${src}/)"
    echo "$files" | grep -qE "$pat" && { echo "$dir"; return 0; }
  done
}
