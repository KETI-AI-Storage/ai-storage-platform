"""
ai-storage-scheduler 의 실제 실행 로그를 알고리즘 적용 로그로 재구성하는 렌더러.

스케줄러(Go) 코드를 전혀 건드리지 않고, 이미 출력되는 slog 텍스트 로그
([filter] / [score-plugin] / [ScoreMap] / [score] / [binding]) 의 실제 값만
파싱해 Filter → Score → Bind 단계, 노드 x 알고리즘 점수 매트릭스,
결정 요인 분석, 후보 Funnel(잔여 후보 수만), K8s 기본 vs KETI 점수 재집계
비교를 출력한다. 측정되지 않은 latency/개선 배율 등은 절대 생성하지 않는다.

27개 알고리즘 분류표는 internal/config/config.go 의 플러그인 등록 내용을
그대로 반영하며 새 알고리즘을 만들지 않는다.

Author: 미정 <unknown>
Created: 2026-05-29
"""

import argparse
import os
import shlex
import sys
from collections import OrderedDict, defaultdict

# ANSI 색상: 캡처 가독성을 위해 사용하되, 비-TTY(파일 리다이렉트)면 자동 비활성화한다.
_USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def _c(code, text):
    """색상 코드를 적용한다(비-TTY면 원문 그대로)."""
    if not _USE_COLOR:
        return text
    return "\033[" + code + "m" + text + "\033[0m"


def bold(t):
    return _c("1", t)


def green(t):
    return _c("32", t)


def yellow(t):
    return _c("33", t)


def cyan(t):
    return _c("36", t)


def dim(t):
    return _c("2", t)


# ============================================================
# 27개 알고리즘 분류표 (근거: internal/config/config.go 등록 내용)
#   group     : 어느 워크로드 스케줄러 유형에서 핵심/강조되는지
#   phase     : config.go 에서 등록된 단계 (대표 단계 기준)
#   is_keti   : KETI 특화 플러그인 여부
#   k8s_score : K8s 기본 Score 플러그인 여부(비교 baseline 계산용)
# ============================================================
ALGORITHMS = OrderedDict([
    # 공통 인프라 필터(전 유형 공유)
    ("NodeName",            {"phase": "Filter",            "is_keti": False, "k8s_score": False, "groups": []}),
    ("NodeUnschedulable",   {"phase": "Filter",            "is_keti": False, "k8s_score": False, "groups": []}),
    ("NodePorts",           {"phase": "Filter",            "is_keti": False, "k8s_score": False, "groups": []}),
    # K8s 기본 Filter+Score
    ("TaintToleration",     {"phase": "Filter+Score",      "is_keti": False, "k8s_score": True,  "groups": ["train"]}),
    ("NodeAffinity",        {"phase": "Filter+Score",      "is_keti": False, "k8s_score": True,  "groups": ["preprocess"]}),
    ("NodeResourcesFit",    {"phase": "Filter",            "is_keti": False, "k8s_score": False, "groups": ["preprocess", "train"]}),
    ("InterPodAffinity",    {"phase": "Filter+Score",      "is_keti": False, "k8s_score": True,  "groups": ["train"]}),
    ("PodTopologySpread",   {"phase": "Filter+Score",      "is_keti": False, "k8s_score": True,  "groups": ["train"]}),
    ("LeastAllocated",      {"phase": "Score",             "is_keti": False, "k8s_score": True,  "groups": ["preprocess"]}),
    ("BalancedAllocation",  {"phase": "Score",             "is_keti": False, "k8s_score": True,  "groups": ["preprocess"]}),
    ("ImageLocality",       {"phase": "Score",             "is_keti": False, "k8s_score": True,  "groups": ["preprocess"]}),
    # 스토리지/볼륨 계열 Filter (+ VolumeBinding 은 Score 도 등록됨)
    ("VolumeRestrictions",  {"phase": "PreFilter+Filter",  "is_keti": False, "k8s_score": False, "groups": ["storage"]}),
    ("VolumeZone",          {"phase": "Filter",            "is_keti": False, "k8s_score": False, "groups": ["storage"]}),
    ("VolumeBinding",       {"phase": "Filter+Score",      "is_keti": False, "k8s_score": True,  "groups": ["storage"]}),
    ("EBSLimits",           {"phase": "Filter",            "is_keti": False, "k8s_score": False, "groups": ["storage"]}),
    ("GCEPDLimits",         {"phase": "Filter",            "is_keti": False, "k8s_score": False, "groups": ["storage"]}),
    ("AzureDiskLimits",     {"phase": "Filter",            "is_keti": False, "k8s_score": False, "groups": ["storage"]}),
    ("NodeVolumeLimits",    {"phase": "Filter",            "is_keti": False, "k8s_score": False, "groups": ["storage"]}),
    # KETI 특화 (Filter+Score)
    ("DataLocalityAware",   {"phase": "Filter+Score",      "is_keti": True,  "k8s_score": False, "groups": ["preprocess"]}),
    ("StorageTierAware",    {"phase": "Filter+Score",      "is_keti": True,  "k8s_score": False, "groups": ["preprocess", "storage"]}),
    ("IOPatternBased",      {"phase": "Filter+Score",      "is_keti": True,  "k8s_score": False, "groups": ["preprocess"]}),
    ("CSIStorageAware",     {"phase": "Filter+Score",      "is_keti": True,  "k8s_score": False, "groups": ["storage"]}),
    ("ShardAware",          {"phase": "Filter+Score",      "is_keti": True,  "k8s_score": False, "groups": ["storage"]}),
    # KETI 특화 (Score only)
    ("KueueAware",          {"phase": "Score",             "is_keti": True,  "k8s_score": False, "groups": ["train"]}),
    ("PipelineStageAware",  {"phase": "Score",             "is_keti": True,  "k8s_score": False, "groups": ["train"]}),
    # PostFilter / Bind
    ("DefaultPreemption",   {"phase": "PostFilter",        "is_keti": False, "k8s_score": False, "groups": ["train"]}),
    ("DefaultBinder",       {"phase": "Bind",              "is_keti": False, "k8s_score": False, "groups": []}),
])

# 워크로드 유형별 화면 강조 알고리즘(요청서 강조 포인트 기준, 실제 등록 플러그인만 사용).
HIGHLIGHT = {
    "preprocess": ["DataLocalityAware", "StorageTierAware", "IOPatternBased"],
    "train":      ["KueueAware", "PipelineStageAware", "NodeResourcesFit"],
    "storage":    ["StorageTierAware", "CSIStorageAware", "ShardAware", "VolumeBinding", "VolumeRestrictions"],
}

TYPE_LABEL = {
    "preprocess": "전처리 스케줄러",
    "train":      "학습/추론 스케줄러",
    "storage":    "스토리지 스케줄러",
}


class Decision:
    """단일 Pod 한 번의 스케줄링 사이클에서 파싱한 실제 결정 데이터."""

    def __init__(self, pod, namespace):
        self.pod = pod
        self.namespace = namespace
        self.total_nodes = None
        self.feasible_nodes = None
        self.gpu_count = 0
        self.has_gpu = False
        # filtered[node] = reason(실제 FilterReason 문자열)
        self.filtered = OrderedDict()
        # scores[node][plugin] = weighted_score(실제 [score-plugin] 로그값)
        self.scores = defaultdict(OrderedDict)
        self.selected_node = None
        self.selected_score = None
        self.bound_node = None
        self.first_ts = None
        self.last_ts = None

    def feasible_node_list(self):
        return list(self.scores.keys())


def parse_kv(line):
    """slog 텍스트 한 줄을 key=value dict 로 파싱한다.

    slog 는 공백 포함 값을 따옴표로 감싸므로 shlex 로 안전하게 토큰화한다.
    """
    try:
        tokens = shlex.split(line.strip())
    except ValueError:
        # 따옴표 짝이 안 맞는 비정상 라인은 건너뛴다.
        return None
    kv = {}
    for tok in tokens:
        if "=" in tok:
            k, _, v = tok.partition("=")
            kv[k] = v
    return kv if kv else None


def _to_int(s, default=0):
    try:
        return int(float(s))
    except (TypeError, ValueError):
        return default


def parse_log(lines, target_pod, target_ns):
    """로그 라인들에서 target_pod 의 마지막 스케줄링 사이클 결정을 추출한다.

    동일 Pod 가 여러 번 등장하면 가장 마지막 'Best node selected' 기준 사이클을
    채택하기 위해, 사이클 경계(Starting scheduling cycle)를 만나면 누적값을 리셋한다.
    """
    dec = Decision(target_pod, target_ns)
    for raw in lines:
        kv = parse_kv(raw)
        if not kv:
            continue
        msg = kv.get("msg", "")
        # Pod 단위 필터링: pod 키가 있으면 대상만, 없으면(전역 로그) 건너뛴다.
        pod = kv.get("pod")
        if pod is not None and pod != target_pod:
            continue
        if target_ns and kv.get("namespace") not in (None, target_ns):
            continue
        ts = kv.get("time")
        if ts:
            if dec.first_ts is None:
                dec.first_ts = ts
            dec.last_ts = ts

        if msg == "[scheduling] Starting pod scheduling":
            # 새 사이클 시작 -> 직전 누적 결과 초기화(가장 최근 사이클만 남기기 위함).
            dec.total_nodes = _to_int(kv.get("total_nodes"), dec.total_nodes or 0)
            dec.filtered = OrderedDict()
            dec.scores = defaultdict(OrderedDict)
            dec.selected_node = None
            dec.selected_score = None
        elif msg == "[scheduling] Pod requests GPU resources":
            dec.has_gpu = True
            dec.gpu_count = _to_int(kv.get("gpu_count"), 0)
        elif msg == "[filter] Node filtered out":
            node = kv.get("node")
            if node:
                dec.filtered[node] = kv.get("reason", "filtered")
        elif msg == "[filter] Filter phase completed":
            dec.feasible_nodes = _to_int(kv.get("feasible_nodes"), dec.feasible_nodes)
            dec.total_nodes = _to_int(kv.get("total_nodes"), dec.total_nodes)
        elif msg == "[score-plugin] Node scored":
            node = kv.get("node")
            plugin = kv.get("plugin")
            if node and plugin:
                dec.scores[node][plugin] = _to_int(kv.get("weighted_score"), 0)
        elif msg == "[score] Best node selected":
            dec.selected_node = kv.get("selected_node")
            dec.selected_score = _to_int(kv.get("score"), None)
        elif msg == "[score] Only one feasible node, skipping score phase":
            dec.selected_node = kv.get("selected_node")
            dec.selected_score = _to_int(kv.get("score"), None)
        elif msg == "[scheduling] Pod successfully bound":
            dec.bound_node = kv.get("node")

    return dec


def detect_type(dec, override):
    """워크로드 스케줄러 유형을 실제 로그 근거로 판정한다(추측 금지).

    근거 우선순위: 사용자 지정 > GPU 요청(train) > 볼륨/스토리지 필터 사유(storage) > 전처리.
    반환: (type, basis_text)
    """
    if override in ("preprocess", "train", "storage"):
        return override, "user override (--type)"
    if dec.has_gpu:
        return "train", "pod requests GPU (gpu_count=%d)" % dec.gpu_count
    # StorageTierAware 는 전처리/스토리지 공용이라 마커에서 제외하고,
    # 볼륨/CSI/PVC 바인딩 계열 사유만 스토리지 신호로 본다.
    storage_markers = ("Volume", "CSI", "PVC", "pvc")
    for node, reason in dec.filtered.items():
        if any(m in reason for m in storage_markers):
            return "storage", "volume/CSI/PVC filter observed (node=%s)" % node
    # KETI 스토리지 플러그인이 점수 단계에 등장하면 스토리지로 본다.
    for node, pm in dec.scores.items():
        if "CSIStorageAware" in pm or "ShardAware" in pm:
            if not ("DataLocalityAware" in pm):
                return "storage", "CSI/Shard scoring observed without data-locality"
    return "preprocess", "no GPU / no storage-filter signal -> default preprocess"


# ----------------------------------------------------------------------------
# 출력 헬퍼
# ----------------------------------------------------------------------------

def hr(title):
    return "━━━ " + title + " ━━━"


def header(dec, wl_type, basis):
    print()
    print(bold("[%s] workload=%s  namespace=%s" % (TYPE_LABEL[wl_type], dec.pod, dec.namespace)))
    print(dim("  scheduler_type_basis : %s" % basis))


def filter_groups(dec):
    """필터 탈락을 사유(=원인 플러그인 추정 문자열) 단위로 묶어 실제 카운트를 만든다."""
    groups = OrderedDict()
    for node, reason in dec.filtered.items():
        groups.setdefault(reason, []).append(node)
    return groups


def print_filter_phase(dec):
    total = dec.total_nodes if dec.total_nodes is not None else (len(dec.filtered) + len(dec.scores))
    feasible = dec.feasible_nodes if dec.feasible_nodes is not None else len(dec.scores)
    print(cyan(hr("Filter Phase")))
    if not dec.filtered:
        print("  %-28s : %d/%d nodes passed" % ("(all filters)", feasible, total))
    else:
        remaining = total
        for reason, nodes in filter_groups(dec).items():
            dropped = len(nodes)
            passed = remaining - dropped
            print("  %s %-26s : %d/%d nodes passed (%s: %s)" % (
                yellow("✗"), _short_reason(reason), passed, remaining,
                "dropped", ", ".join(nodes)))
            remaining = passed
    print("  %-28s : %d node(s)" % ("feasible_after_filter", feasible))


def _short_reason(reason):
    """필터 사유 문자열을 28자 안쪽 라벨로 줄인다(원문은 funnel/verbose 에서 노출)."""
    r = reason.strip()
    if len(r) <= 40:
        return r
    return r[:37] + "..."


def _highlight_plugins(dec, wl_type, verbose):
    """매트릭스/Score 단계에 노출할 플러그인 집합을 결정한다."""
    present = OrderedDict()
    for node, pm in dec.scores.items():
        for p in pm:
            present[p] = True
    present_list = list(present.keys())
    if verbose:
        return present_list
    hi = [p for p in HIGHLIGHT.get(wl_type, []) if p in present]
    # 강조 플러그인이 로그에 없으면 등장한 KETI 플러그인으로 대체한다.
    if not hi:
        hi = [p for p in present_list if ALGORITHMS.get(p, {}).get("is_keti")]
    if not hi:
        hi = present_list[:4]
    return hi


def print_score_phase(dec, wl_type, verbose):
    print(cyan(hr("Score Phase")))
    plugins = _highlight_plugins(dec, wl_type, verbose)
    if not plugins:
        print("  " + dim("no score-plugin logs found (filter-only decision)"))
        return
    nodes = dec.feasible_node_list()
    for p in plugins:
        parts = []
        for n in nodes:
            v = dec.scores[n].get(p)
            parts.append("%s=%s" % (n, "-" if v is None else v))
        print("  %-26s : %s" % (p, ", ".join(parts)))


def _winner(dec):
    """실제 점수 합 기준 승자(없으면 selected_node)."""
    if dec.selected_node:
        return dec.selected_node
    best, best_s = None, -1
    for n, pm in dec.scores.items():
        s = sum(pm.values())
        if s > best_s:
            best, best_s = n, s
    return best


def _discriminators(dec, win):
    """승자와 차순위 노드 간 점수 격차(변별 기여)를 플러그인별로 반환한다."""
    others = [n for n in dec.feasible_node_list() if n != win]
    runner = max(others, key=lambda n: sum(dec.scores[n].values())) if others else None
    margin = {}
    for p, v in dec.scores.get(win, {}).items():
        rv = dec.scores[runner].get(p, 0) if runner else v
        margin[p] = v - rv
    return runner, margin


def _main_reason(dec, wl_type):
    """승자 선택의 실제 변별 요인(차순위 대비 +격차 상위) 기반 1줄 사유."""
    win = _winner(dec)
    if not win or win not in dec.scores:
        return "single feasible node or filter-only decision"
    runner, margin = _discriminators(dec, win)
    if not runner:
        # 후보가 1개뿐이면 절대 점수 상위로 표기.
        top = sorted(dec.scores[win].items(), key=lambda kv: kv[1], reverse=True)[:2]
        return " + ".join("%s(%d)" % (k, v) for k, v in top if v > 0) or "single feasible node"
    top = sorted(margin.items(), key=lambda kv: kv[1], reverse=True)[:2]
    top = [(k, v) for k, v in top if v > 0]
    if not top:
        return "tie on score; selected by ordering"
    return " + ".join("%s(+%d)" % (k, v) for k, v in top)


def print_bind_phase(dec, wl_type):
    print(cyan(hr("Bind Decision")))
    win = _winner(dec)
    total = dec.selected_score
    if total is None and win in dec.scores:
        total = sum(dec.scores[win].values())
    print("  %-26s : %s" % ("selected_node", green(str(win)) if win else "n/a"))
    print("  %-26s : %s" % ("total_score", "n/a" if total is None else str(total)))
    print("  %-26s : %s" % ("main_reason", _main_reason(dec, wl_type)))
    if dec.bound_node:
        ok = "✓" if dec.bound_node == win else "⚠"
        print("  %-26s : %s %s" % ("bind_confirmed", ok, dec.bound_node))


def print_matrix(dec, wl_type, verbose):
    """노드 x 알고리즘 점수 매트릭스. 승자=★, 필터=FILTERED, 미산정=-."""
    print(cyan(hr("Score Matrix (weighted)")))
    plugins = _highlight_plugins(dec, wl_type, verbose)
    if not plugins:
        print("  " + dim("no score-plugin logs found"))
        return
    win = _winner(dec)
    # 헤더
    colw = 14
    head = "%-18s" % "node"
    for p in plugins:
        head += "| %-*s" % (colw, p[:colw])
    head += "| %-7s" % "TOTAL"
    print("  " + bold(head))
    print("  " + "-" * len(head))
    # 점수 행 (feasible)
    for n in dec.feasible_node_list():
        row = "%-18s" % n
        for p in plugins:
            v = dec.scores[n].get(p)
            row += "| %-*s" % (colw, "-" if v is None else str(v))
        total = sum(dec.scores[n].values())
        star = " ★" if n == win else ""
        row += "| %-7s" % (str(total) + star)
        print("  " + (green(row) if n == win else row))
    # 필터 행
    for n, reason in dec.filtered.items():
        row = "%-18s" % n
        for _ in plugins:
            row += "| %-*s" % (colw, "-")
        row += "| %-7s" % "FILTERED"
        print("  " + yellow(row))


def print_decision_factors(dec, wl_type):
    """승자 노드의 결정 요인(점수+비율). 변별 기여가 가장 큰 알고리즘에 decisive 표기."""
    print(cyan(hr("Decision Factor Analysis")))
    win = _winner(dec)
    if not win or win not in dec.scores or not dec.scores[win]:
        print("  " + dim("no per-plugin scores for winner (single-node or filter-only)"))
        return
    pm = dec.scores[win]
    total = sum(pm.values())

    # 변별 기여: 승자와 차순위 노드 간 플러그인별 점수 격차.
    # 모든 노드에 같은 점수를 주는 플러그인(격차 0)은 절대점수가 높아도
    # 실제 선택에는 기여하지 않으므로 decisive 판정에서 제외한다.
    runner, margin = _discriminators(dec, win)
    decisive_plugin = max(margin, key=margin.get) if margin else None
    if decisive_plugin is not None and margin[decisive_plugin] <= 0:
        decisive_plugin = None  # 변별 기여가 있는 플러그인이 없음

    print("  Winner: %s%s" % (green(win), ("  (runner-up: %s)" % runner) if runner else ""))
    print("  %-26s : %s" % ("total_score", "%d" % total))
    print()
    ordered = sorted(pm.items(), key=lambda kv: kv[1], reverse=True)
    for p, v in ordered:
        ratio = (v * 100.0 / total) if total else 0.0
        tag = ""
        if p == decisive_plugin:
            tag = "  " + bold(green("decisive +%d vs runner-up" % margin[p]))
        elif runner and margin.get(p, 0) == 0:
            tag = "  " + dim("(no node discrimination)")
        print("  %-26s : %4d점  (%5.1f%%)%s" % (p, v, ratio, tag))
    print()
    if decisive_plugin:
        print("  insight : %s 가 차순위(%s) 대비 +%d 로 결정 요인이 되어 %s 가 선택됨"
              % (decisive_plugin, runner, margin[decisive_plugin], win))
    else:
        print("  insight : 단일 후보 또는 점수 동률로 결정 요인 플러그인 없음")


def print_funnel(dec, wl_type):
    """후보 노드 Funnel. 측정되지 않은 단계별 ms 는 만들지 않고, 실제 잔여 후보만 표시."""
    print(cyan(hr("Candidate Funnel (real counts)")))
    total = dec.total_nodes if dec.total_nodes is not None else (len(dec.filtered) + len(dec.scores))
    feasible = dec.feasible_nodes if dec.feasible_nodes is not None else len(dec.scores)
    win = _winner(dec)
    print("  ● candidates                 : %d node(s)" % total)
    remaining = total
    for reason, nodes in filter_groups(dec).items():
        remaining -= len(nodes)
        print("  → %-26s : %d node(s)  (drop %d: %s)" % (
            _short_reason(reason), remaining, len(nodes), ", ".join(nodes)))
    print("  → %-26s : %d node(s)" % ("feasible (scored)", feasible))
    print("  ★ %-26s : %s" % ("selected_node", green(str(win)) if win else "n/a"))
    # 타임라인 ms 는 단계별로 측정되지 않으므로 절대 추정해서 출력하지 않는다.
    if dec.first_ts and dec.last_ts:
        print(dim("  note: 단계별 latency 는 스케줄러가 측정하지 않아 생략 (cycle window: %s ~ %s)"
                   % (dec.first_ts, dec.last_ts)))


def print_compare(dec, wl_type):
    """K8s 기본 Score 플러그인만 vs KETI 전체 점수로 승자를 재계산해 비교(실데이터 재집계).

    latency 등 측정되지 않은 값은 절대 만들지 않는다.
    """
    print(cyan(hr("Before/After (K8s-default vs KETI, recomputed from real scores)")))
    nodes = dec.feasible_node_list()
    if not nodes:
        print("  " + dim("no scored nodes to compare"))
        return

    def winner_subset(use_keti):
        best, best_s, basis = None, -1, []
        for n in nodes:
            pm = dec.scores[n]
            s = 0
            for p, v in pm.items():
                meta = ALGORITHMS.get(p, {})
                if use_keti:
                    s += v
                elif meta.get("k8s_score"):
                    s += v
            if s > best_s:
                best, best_s = n, s
        return best, best_s

    k8s_node, k8s_s = winner_subset(use_keti=False)
    keti_node, keti_s = winner_subset(use_keti=True)

    def basis_of(node, use_keti):
        pm = dec.scores.get(node, {})
        items = [(p, v) for p, v in pm.items()
                 if (use_keti or ALGORITHMS.get(p, {}).get("k8s_score"))]
        items.sort(key=lambda kv: kv[1], reverse=True)
        return ", ".join("%s(%d)" % (p, v) for p, v in items[:3] if v > 0) or "n/a"

    print("  [K8s Default only]  (TaintToleration/NodeAffinity/LeastAllocated/Balanced/ImageLocality/InterPodAffinity/PodTopologySpread/VolumeBinding)")
    print("    %-24s : %s" % ("selected_node", str(k8s_node)))
    print("    %-24s : %s" % ("score(k8s subset)", str(k8s_s)))
    print("    %-24s : %s" % ("decision_basis", basis_of(k8s_node, False)))
    print()
    print("  [K8s + KETI %s]" % TYPE_LABEL[wl_type])
    print("    %-24s : %s" % ("selected_node", green(str(keti_node))))
    print("    %-24s : %s" % ("score(full)", str(keti_s)))
    print("    %-24s : %s" % ("decision_basis", basis_of(keti_node, True)))
    print()
    print("  [Difference]")
    if k8s_node == keti_node:
        print("    %-24s : %s" % ("selected_node", "동일 (%s)" % keti_node))
        print("    %-24s : %s" % ("note", "KETI 가중치가 같은 노드를 더 강하게 지지"))
    else:
        print("    %-24s : %s → %s" % ("selected_node", k8s_node, green(keti_node)))
    delta = sum(v for p, v in dec.scores.get(keti_node, {}).items()
                if ALGORITHMS.get(p, {}).get("is_keti"))
    print("    %-24s : +%d (KETI 플러그인 기여 합, 실제 weighted)" % ("keti_score_contribution", delta))
    print(dim("    note: io_latency_ms / 단계별 t=ms / 개선 배율 등 측정되지 않은 값은 표시하지 않음"))


def render(dec, mode, wl_type, basis, verbose):
    """ALGORITHM_LOG_MODE/SCHEDULER_LOG_MODE 에 따라 섹션을 출력한다.

    full 모드는 모든 섹션을, 단일 섹션 모드는 해당 섹션만 출력한다.
    """
    header(dec, wl_type, basis)
    if mode in ("basic", "verbose", "full"):
        print_filter_phase(dec)
        print_score_phase(dec, wl_type, verbose or mode == "verbose")
        print_bind_phase(dec, wl_type)
    if mode in ("matrix", "full"):
        print_matrix(dec, wl_type, verbose)
    if mode in ("funnel", "full"):
        print_funnel(dec, wl_type)
    if mode in ("compare", "full"):
        print_compare(dec, wl_type)
    if mode == "full":
        print_decision_factors(dec, wl_type)
    print()


def print_algo_table():
    """27개 알고리즘 분류표를 출력한다(코드 등록 기준)."""
    print(bold("27 Scheduling Algorithms (source: internal/config/config.go)"))
    print("%-3s %-20s %-22s %-8s %-8s" % ("#", "name", "phase", "keti", "groups"))
    print("-" * 70)
    for i, (name, meta) in enumerate(ALGORITHMS.items(), 1):
        print("%-3d %-20s %-22s %-8s %-8s" % (
            i, name, meta["phase"], "Y" if meta["is_keti"] else "-",
            ",".join(meta["groups"]) or "-"))


def main():
    ap = argparse.ArgumentParser(description="ai-storage-scheduler 알고리즘 적용 로그 렌더러")
    ap.add_argument("--pod", help="대상 Pod 이름 (로그의 pod= 값)")
    ap.add_argument("--namespace", default="", help="대상 namespace (선택)")
    ap.add_argument("--log-file", help="스케줄러 로그 파일 경로 (미지정 시 stdin)")
    ap.add_argument("--type", default="auto",
                    choices=["auto", "preprocess", "train", "storage"],
                    help="스케줄러 유형(기본 auto: 로그 근거로 판정)")
    # 환경변수 우선순위: ALGORITHM_LOG_MODE > SCHEDULER_LOG_MODE > 기본 basic
    _env_mode = (os.environ.get("ALGORITHM_LOG_MODE")
                 or os.environ.get("SCHEDULER_LOG_MODE")
                 or "basic")
    ap.add_argument("--mode", default=_env_mode,
                    choices=["basic", "verbose", "full", "matrix", "funnel", "compare"],
                    help="출력 수준 (env ALGORITHM_LOG_MODE 또는 SCHEDULER_LOG_MODE 로도 지정 가능)")
    ap.add_argument("--list-algorithms", action="store_true",
                    help="27개 알고리즘 분류표만 출력하고 종료")
    args = ap.parse_args()

    if args.list_algorithms:
        print_algo_table()
        return 0

    if not args.pod:
        ap.error("--pod 는 필수입니다 (--list-algorithms 제외)")

    if args.log_file:
        with open(args.log_file, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    else:
        lines = sys.stdin.readlines()

    dec = parse_log(lines, args.pod, args.namespace)
    if dec.total_nodes is None and not dec.scores and not dec.filtered:
        print(yellow("⚠ pod=%s 에 대한 스케줄링 로그를 찾지 못했습니다." % args.pod))
        print(dim("  확인: 로그에 'pod=%s' 가 있는지, 스케줄러가 해당 Pod 를 처리했는지 점검하세요." % args.pod))
        return 2

    wl_type, basis = detect_type(dec, args.type if args.type != "auto" else None)
    verbose = args.mode == "verbose"
    render(dec, args.mode, wl_type, basis, verbose)
    return 0


if __name__ == "__main__":
    sys.exit(main())
