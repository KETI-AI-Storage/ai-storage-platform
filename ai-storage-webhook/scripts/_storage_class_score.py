#!/usr/bin/env python3
"""ai-storage-webhook selectStorageClass() scoring을 Gluesys L1/L2/L3/S3 기준으로 미러링한다.

ai-storage-webhook/pkg/webhook/mutate.go 의 selectStorageClass() 와 동일한
filter + per-SC score sum + tie-break 로직을 구현한다. PVC JSON 을 stdin 으로 받는다.

Env: POD_NAME, PVC_NAME, NAMESPACE, WORKLOAD_DISPLAY (Job/app title for header).

Author: 미정 <unknown@keti.io>
Created: 미정
"""
from __future__ import annotations

import json
import os
import sys
from typing import Any, Dict, List, Optional, Tuple

STORAGE_TIER_ANNOTATION = "storage-tier"

# Gluesys 4-tier 표준 StorageClass 이름. 기존 storage-burst/performance/capacity/archive 는
# 호환 입력으로만 인식하고 최종 결과는 L1~S3 만 사용한다.
SC_L1 = "storage-l1"
SC_L2 = "storage-l2"
SC_L3 = "storage-l3"
SC_S3 = "storage-s3"

# 표준 tier 이름. PVC selected-tier annotation 과 동일 기준.
TIER_L1 = "L1"
TIER_L2 = "L2"
TIER_L3 = "L3"
TIER_S3 = "S3"

# 2단계 rule + 3단계 Hard/Score rule 선정용 PVC annotation 키.
# 웹훅의 hardRuleSelect() / scoreRuleSelect() 와 동일한 우선순위로 동작한다.
TIER_HINT_KEY = "storage.keti.io/tier-hint"
DATA_ROLE_KEY = "storage.keti.io/data-role"
WORKLOAD_TYPE_HINT_KEY = "storage.keti.io/workload-type"
PRIORITY_KEY = "storage.keti.io/priority"
WEIGHT_KEY = "storage.keti.io/weight"
IO_PATTERN_KEY = "storage.keti.io/io-pattern"
ACCESS_PATTERN_KEY = "storage.keti.io/access-pattern"
LATENCY_KEY = "storage.keti.io/latency"

TIER_TO_SC = {
    TIER_L1: SC_L1,
    TIER_L2: SC_L2,
    TIER_L3: SC_L3,
    TIER_S3: SC_S3,
}

WORKLOAD_TYPE_KEYS = ("workload.keti.io/type", "workload.keti.io/type")
STAGE_KEYS = ("stage", "ai-storage/stage")
GPU_KEYS = ("gpuCount", "gpu-count", "ai-storage/gpu-count")
FRAMEWORK_KEYS = (
    "workload.keti.io/framework",
    "framework",
    "ai-storage/framework",
)
WORKLOAD_KIND_KEY = "workload.keti.io/kind"
MOUNT_PATH_KEY = "workload.keti.io/mount-path"
READ_ONLY_KEY = "workload.keti.io/read-only"
PVC_COUNT_KEY = "workload.keti.io/pvc-count"
REPLICA_COUNT_KEY = "workload.keti.io/replica-count"

# Empty => accessMode filter skipped (same as default storageClassSupportedAccessModes)
STORAGE_CLASS_SUPPORTED_ACCESS_MODES: Dict[str, List[str]] = {}


def get_metadata_value_from_maps(
    labels: Optional[Dict[str, str]], annotations: Optional[Dict[str, str]], keys: Tuple[str, ...]
) -> str:
    for k in keys:
        if annotations and k in annotations and str(annotations[k]).strip():
            return str(annotations[k]).strip()
        if labels and k in labels and str(labels[k]).strip():
            return str(labels[k]).strip()
    return ""


def normalize_workload_type(raw: str) -> Tuple[str, bool]:
    s = raw.lower().strip()
    if s in ("preprocess", "preprocessing"):
        return "preprocess", True
    if s in ("train", "training"):
        return "train", True
    if s in ("infer", "inference"):
        return "infer", True
    return "", False


def extract_workload_type(labels: Dict[str, str], annotations: Dict[str, str]) -> Tuple[str, bool]:
    raw = get_metadata_value_from_maps(labels, annotations, WORKLOAD_TYPE_KEYS)
    if raw:
        wt, ok = normalize_workload_type(raw)
        if ok:
            return wt, True
    stage = get_metadata_value_from_maps(labels, annotations, STAGE_KEYS)
    sl = stage.lower().strip()
    if sl == "train":
        return "train", True
    if sl == "preprocess":
        return "preprocess", True
    if sl == "inference":
        return "infer", True
    return "", False


def normalize_framework(raw: str) -> str:
    return raw.lower().strip()


def extract_framework(labels: Dict[str, str], annotations: Dict[str, str]) -> Tuple[str, bool]:
    raw = get_metadata_value_from_maps(labels, annotations, FRAMEWORK_KEYS)
    raw = normalize_framework(raw)
    if not raw:
        return "", False
    return raw, True


def extract_gpu_count(labels: Dict[str, str], annotations: Dict[str, str]) -> Tuple[int, bool]:
    raw = get_metadata_value_from_maps(labels, annotations, GPU_KEYS)
    if not str(raw).strip():
        return 0, False
    try:
        n = int(str(raw).strip())
        if n < 0:
            return 0, False
        return n, True
    except ValueError:
        return 0, False


def extract_workload_kind(labels: Dict[str, str], annotations: Dict[str, str]) -> Tuple[str, bool]:
    raw = get_metadata_value_from_maps(labels, annotations, (WORKLOAD_KIND_KEY,))
    if not str(raw).strip():
        return "", False
    s = str(raw).lower().strip()
    if s == "job":
        return "Job", True
    if s in ("cronjob", "cron_job", "cron-job"):
        return "CronJob", True
    if s == "deployment":
        return "Deployment", True
    if s == "statefulset":
        return "StatefulSet", True
    return "", False


def extract_mount_path(labels: Dict[str, str], annotations: Dict[str, str]) -> Tuple[str, bool]:
    raw = get_metadata_value_from_maps(labels, annotations, (MOUNT_PATH_KEY,))
    raw = raw.strip()
    if not raw:
        return "", False
    return raw, True


def extract_read_only(labels: Dict[str, str], annotations: Dict[str, str]) -> Tuple[bool, bool]:
    raw = get_metadata_value_from_maps(labels, annotations, (READ_ONLY_KEY,))
    raw = raw.lower().strip()
    if not raw:
        return False, False
    if raw in ("true", "1", "yes", "y"):
        return True, True
    if raw in ("false", "0", "no", "n"):
        return False, True
    return False, False


def extract_pvc_count(labels: Dict[str, str], annotations: Dict[str, str]) -> Tuple[int, bool]:
    raw = get_metadata_value_from_maps(labels, annotations, (PVC_COUNT_KEY,)).strip()
    if not raw:
        return 0, False
    try:
        n = int(raw)
        if n < 0:
            return 0, False
        return n, True
    except ValueError:
        return 0, False


def extract_replica_count(labels: Dict[str, str], annotations: Dict[str, str]) -> Tuple[int, bool]:
    raw = get_metadata_value_from_maps(labels, annotations, (REPLICA_COUNT_KEY,)).strip()
    if not raw:
        return 0, False
    try:
        n = int(raw)
        if n < 0:
            return 0, False
        return n, True
    except ValueError:
        return 0, False


def hard_rule_select(
    labels: Dict[str, str], annotations: Dict[str, str]
) -> Tuple[str, str, bool]:
    """3단계 Hard Rule: tier-hint, archive-계열 data-role, cache+조합을 평가한다.

    웹훅의 hardRuleSelect() 와 동일한 우선순위로 동작한다. 매칭되면 즉시 tier 를
    확정하여 score 로직을 우회한다.

    Args:
        labels (Dict[str, str]): PVC labels.
        annotations (Dict[str, str]): PVC annotations.

    Returns:
        Tuple[str, str, bool]: (tier, reason, matched).
    """
    def read(key: str) -> str:
        return get_metadata_value_from_maps(labels, annotations, (key,))

    # 1) tier-hint
    raw = read(TIER_HINT_KEY)
    if raw:
        if raw in (TIER_L1, TIER_L2, TIER_L3, TIER_S3):
            return raw, f"tier-hint={raw} (final)", True
        norm, _ = normalize_tier(raw)
        if norm:
            return norm, f"tier-hint={raw} -> {norm} (legacy normalize)", True

    role = read(DATA_ROLE_KEY).lower()

    # 2) data-role archive 계열 → S3 강제
    if role in ("archive", "backup", "result-backup", "old-log"):
        return TIER_S3, f"data-role={role} -> S3 (hard)", True

    # 3) data-role cache 계열 + (access=repeated OR latency=ultra-low) → L1 강제
    if role in ("cache", "metadata-cache", "repeated-access", "shard-index-cache"):
        ap = read(ACCESS_PATTERN_KEY).lower()
        lat = read(LATENCY_KEY).lower()
        if ap == "repeated" or lat == "ultra-low":
            return TIER_L1, f"data-role={role} + (access-pattern={ap}|latency={lat}) -> L1 (hard)", True

    return "", "", False


def score_rule_select(
    labels: Dict[str, str], annotations: Dict[str, str]
) -> Tuple[str, List[Tuple[str, str, List[int]]], Dict[str, int], bool]:
    """AHP 기반 점수 합산. tier 별 (L1/L2/L3/S3) 100점 스케일 가중치.

    웹훅의 scoreRuleSelect() 와 동일한 표/순서/tie-break 를 사용한다.

    Returns:
        Tuple[str, List[Tuple[str, str, List[int]]], Dict[str, int], bool]:
            (tier, contributions, scores, has_input).
            contributions: 각 항목별 (category, value, [L1,L2,L3,S3] pts).
            scores: tier -> 총점.
            has_input=False 면 default L2 폴백.
    """
    def read(key: str) -> str:
        return get_metadata_value_from_maps(labels, annotations, (key,))

    scores: Dict[str, int] = {TIER_L1: 0, TIER_L2: 0, TIER_L3: 0, TIER_S3: 0}
    contribs: List[Tuple[str, str, List[int]]] = []
    has_input = False

    def add(key: str, value: str, l1: int, l2: int, l3: int, s3: int) -> None:
        scores[TIER_L1] += l1
        scores[TIER_L2] += l2
        scores[TIER_L3] += l3
        scores[TIER_S3] += s3
        contribs.append((key, value, [l1, l2, l3, s3]))

    # 1) data-role (50)
    raw = read(DATA_ROLE_KEY)
    if raw:
        has_input = True
        s = raw.lower()
        if s in ("cache", "metadata-cache", "repeated-access", "shard-index-cache"):
            add("data-role", raw, 50, 0, 0, 0)
        elif s in ("preprocessing-input", "training-input", "inference-input", "hot-data", "input"):
            add("data-role", raw, 0, 50, 0, 0)
        elif s in ("raw-dataset", "intermediate", "warm-data", "cold-data"):
            add("data-role", raw, 0, 0, 50, 0)
        elif s in ("backup", "archive", "result-backup", "old-log"):
            add("data-role", raw, 0, 0, 0, 50)

    # 2) workload-type (25)
    raw = read(WORKLOAD_TYPE_HINT_KEY)
    if raw:
        has_input = True
        s = raw.lower()
        if s in ("preprocessing", "training", "inference"):
            add("workload-type", raw, 0, 25, 0, 0)
        elif s == "dataset-ingest":
            add("workload-type", raw, 0, 0, 25, 0)
        elif s == "archive":
            add("workload-type", raw, 0, 0, 0, 25)

    # 3) access-pattern (15~30)
    raw = read(ACCESS_PATTERN_KEY)
    if raw:
        has_input = True
        s = raw.lower()
        if s == "repeated":
            add("access-pattern", raw, 30, 0, 0, 0)
        elif s == "frequent":
            add("access-pattern", raw, 0, 20, 0, 0)
        elif s == "occasional":
            add("access-pattern", raw, 0, 0, 15, 0)
        elif s == "rare":
            add("access-pattern", raw, 0, 0, 0, 20)

    # 4) latency (15~30) — 수치/legacy 는 무시
    raw = read(LATENCY_KEY)
    if raw:
        s = raw.lower()
        if s == "ultra-low":
            has_input = True
            add("latency", raw, 30, 0, 0, 0)
        elif s == "low":
            has_input = True
            add("latency", raw, 0, 25, 0, 0)
        elif s == "normal":
            has_input = True
            add("latency", raw, 0, 0, 15, 0)
        elif s == "high-ok":
            has_input = True
            add("latency", raw, 0, 0, 0, 20)

    # 5) io-pattern (10~20)
    raw = read(IO_PATTERN_KEY)
    if raw:
        has_input = True
        s = raw.lower()
        if s in ("small-random-read", "metadata-read"):
            add("io-pattern", raw, 20, 0, 0, 0)
        elif s in ("large-read", "large-sequential-read"):
            add("io-pattern", raw, 0, 15, 10, 0)
        elif s == "large-write":
            add("io-pattern", raw, 0, 0, 15, 10)

    # 6) priority (5~10)
    raw = read(PRIORITY_KEY)
    if raw:
        has_input = True
        s = raw.lower()
        if s == "high":
            add("priority", raw, 5, 10, 0, 0)
        elif s == "medium":
            add("priority", raw, 0, 5, 5, 0)
        elif s == "low":
            add("priority", raw, 0, 0, 5, 10)

    # 7) weight (5)
    raw = read(WEIGHT_KEY)
    if raw:
        try:
            w = float(raw)
            has_input = True
            if w >= 1.5:
                add("weight", raw, 5, 5, 0, 0)
            elif w >= 1.0:
                add("weight", raw, 0, 5, 0, 0)
            else:
                add("weight", raw, 0, 0, 5, 0)
        except ValueError:
            pass

    if not has_input:
        return TIER_L2, contribs, scores, False

    tier = pick_tier_by_score(scores)
    return tier, contribs, scores, True


def pick_tier_by_score(scores: Dict[str, int]) -> str:
    """동점 시 L2 > L3 > L1 > S3 순으로 폴백.

    L1 단독 승격 방지(priority=high, weight=2.0 단독 입력에서 L1 으로 가지 않게)
    하기 위한 정책 우선순위다.
    """
    order = [TIER_L2, TIER_L3, TIER_L1, TIER_S3]
    best_tier = order[0]
    best_pts = scores[best_tier]
    for t in order[1:]:
        if scores[t] > best_pts:
            best_tier = t
            best_pts = scores[t]
    return best_tier


def build_tier_reason(
    path: str,
    tier: str,
    sc: str,
    scores: Dict[str, int],
    contribs: List[Tuple[str, str, List[int]]],
    hard_reason: str,
) -> str:
    """웹훅 buildTierReason() 와 동일 형식의 tier-reason 문자열을 생성한다."""
    tier_idx = {TIER_L1: 0, TIER_L2: 1, TIER_L3: 2, TIER_S3: 3}
    idx = tier_idx.get(tier, 1)
    parts: List[str] = []
    for key, value, pts in contribs:
        if pts[idx] > 0:
            parts.append(f"{key}={value}(+{pts[idx]})")
    if hard_reason:
        reason_body = hard_reason
    elif parts:
        reason_body = ", ".join(parts)
    else:
        reason_body = "no-contribution"
    s = scores
    return (
        f"selection-path={path}; selected={tier}; storage-class={sc}; "
        f"scores={{L1:{s[TIER_L1]},L2:{s[TIER_L2]},L3:{s[TIER_L3]},S3:{s[TIER_S3]}}}; "
        f"reason={reason_body}"
    )


def normalize_tier(raw_tier: str) -> Tuple[str, str]:
    """입력 tier 값을 Gluesys L1/L2/L3/S3 표준으로 정규화한다.

    Args:
        raw_tier (str): PVC annotation/label 등에서 들어온 tier 문자열.

    Returns:
        Tuple[str, str]: (표준 tier, 매핑된 StorageClass). 인식 실패 시 ("", "").

    Example:
        >>> normalize_tier("burst")
        ('L1', 'storage-l1')
        >>> normalize_tier("L3")
        ('L3', 'storage-l3')
    """
    s = raw_tier.lower().strip()
    if s in ("l1", "burst", "cache"):
        return TIER_L1, SC_L1
    if s in ("l2", "performance"):
        return TIER_L2, SC_L2
    if s in ("l3", "capacity"):
        return TIER_L3, SC_L3
    if s in ("s3", "archive"):
        return TIER_S3, SC_S3
    return "", ""


def filter_candidates(
    candidates: List[str],
    access_modes: List[str],
) -> Tuple[List[str], List[str]]:
    filtered: List[str] = []
    filter_debug: List[str] = []
    for sc in candidates:
        supported = STORAGE_CLASS_SUPPORTED_ACCESS_MODES.get(sc)
        if supported and len(supported) > 0:
            all_supported = True
            for req in access_modes:
                if req not in supported:
                    all_supported = False
                    break
            if not all_supported:
                filter_debug.append(f"{sc} filtered(accessMode)")
                continue
        filtered.append(sc)
    if not filtered:
        filtered = [SC_S3]
    return filtered, filter_debug


def fw_category(framework: str) -> str:
    if framework in ("pytorch", "torch", "tensorflow"):
        return "learning"
    if framework in ("spark", "airflow"):
        return "pipeline"
    if framework in ("triton", "onnxruntime"):
        return "serving"
    return ""


def get_workload_type_pts(sc: str, workload_type: str, known: bool) -> int:
    if not known:
        return 0
    wt = workload_type
    if wt == "preprocess":
        if sc == SC_L1:
            return 2
        if sc in (SC_L2, SC_L3):
            return 1
        return 0
    if wt == "train":
        if sc == SC_L2:
            return 2
        if sc in (SC_L1, SC_L3):
            return 1
        return 0
    if wt == "infer":
        if sc == SC_L3:
            return 2
        if sc == SC_L2:
            return 1
        if sc == SC_L1:
            return 0
        return 0
    return 0


def get_gpu_points(sc: str, gpu_count: int, known: bool) -> int:
    if not known:
        return 0
    if gpu_count >= 1:
        if sc == SC_L2:
            return 2
        if sc == SC_L3:
            return 1
        return 0
    if sc == SC_L1:
        return 1
    if sc == SC_L3:
        return 1
    return 0


def get_workload_kind_pts(sc: str, workload_kind: str, known: bool) -> int:
    if not known:
        return 0
    wk = workload_kind
    if wk == "Job":
        if sc == SC_L1:
            return 2
        if sc == SC_L2:
            return 2
        if sc == SC_L3:
            return 1
        return 0
    if wk == "CronJob":
        if sc == SC_L1:
            return 2
        if sc == SC_L3:
            return 1
        return 0
    if wk == "Deployment":
        if sc == SC_L3:
            return 2
        if sc == SC_L2:
            return 1
        return 0
    if wk == "StatefulSet":
        if sc == SC_L3:
            return 2
        if sc in (SC_L1, SC_L2):
            return 1
        return 0
    return 0


def get_volume_mount_pts(sc: str, mount_path: str, known: bool) -> int:
    if not known:
        return 0
    mp = mount_path
    if mp == "/cache":
        return 2 if sc == SC_L1 else 0
    if mp in ("/input", "/output"):
        if sc == SC_L1:
            return 2
        if sc == SC_L3:
            return 1
        return 0
    if mp == "/checkpoint":
        return 2 if sc == SC_L2 else 0
    if mp == "/model":
        if sc == SC_L3:
            return 2
        if sc == SC_L2:
            return 1
        return 0
    if mp in ("/data", "/dataset"):
        if sc in (SC_L1, SC_L2, SC_L3):
            return 1
        return 0
    if mp.startswith("/data/") or mp.startswith("/dataset/"):
        if sc in (SC_L1, SC_L2, SC_L3):
            return 1
        return 0
    if mp.startswith("/cache/"):
        return 2 if sc == SC_L1 else 0
    return 0


def get_framework_pts(sc: str, fw_cat: str) -> int:
    if not fw_cat:
        return 0
    if fw_cat == "learning":
        if sc == SC_L2:
            return 2
        if sc == SC_L3:
            return 1
        return 0
    if fw_cat == "pipeline":
        if sc == SC_L1:
            return 2
        if sc == SC_L3:
            return 1
        return 0
    if fw_cat == "serving":
        if sc == SC_L3:
            return 2
        if sc == SC_L2:
            return 1
        return 0
    return 0


def get_read_only_pts(sc: str, read_only: bool, known: bool) -> int:
    if not known:
        return 0
    if read_only:
        if sc == SC_L3:
            return 2
        if sc == SC_S3:
            return 1
        return 0
    if sc == SC_L1:
        return 2
    if sc == SC_L2:
        return 1
    return 0


def get_pvc_pts(sc: str, pvc_count: int, known: bool) -> int:
    if not known:
        return 0
    if pvc_count == 1:
        return 1 if sc == SC_L3 else 0
    if pvc_count >= 2:
        if sc == SC_L1:
            return 2
        if sc == SC_L2:
            return 1
        return 0
    return 0


def get_replica_pts(sc: str, replicas: int, known: bool) -> int:
    if not known:
        return 0
    if replicas <= 1:
        return 1 if sc == SC_L3 else 0
    return 2 if sc == SC_L3 else 0


def score_storage_classes(pvc: Dict[str, Any]) -> None:
    labels = pvc.get("metadata", {}).get("labels") or {}
    annotations = pvc.get("metadata", {}).get("annotations") or {}
    spec = pvc.get("spec") or {}
    access_modes = spec.get("accessModes") or []

    candidates = [SC_L1, SC_L2, SC_L3, SC_S3]
    exp_raw = get_metadata_value_from_maps(labels, annotations, (STORAGE_TIER_ANNOTATION,))
    exp_tier, exp_class = normalize_tier(exp_raw)
    if exp_tier and exp_class:
        candidates = [exp_class]

    workload_type, workload_type_known = extract_workload_type(labels, annotations)
    framework, framework_known = extract_framework(labels, annotations)
    gpu_count, gpu_count_known = extract_gpu_count(labels, annotations)
    if gpu_count < 0:
        gpu_count = 0
    workload_kind, workload_kind_known = extract_workload_kind(labels, annotations)
    mount_path, mount_path_known = extract_mount_path(labels, annotations)
    read_only, read_only_known = extract_read_only(labels, annotations)
    pvc_count, pvc_count_known = extract_pvc_count(labels, annotations)
    replicas, replica_known = extract_replica_count(labels, annotations)

    fw_cat = fw_category(framework) if framework_known else ""

    filtered, _filter_debug = filter_candidates(candidates, access_modes)

    scores: Dict[str, int] = {}
    score_reasons: Dict[str, List[str]] = {}

    for sc in filtered:
        total = 0
        reasons: List[str] = []

        pts = get_workload_type_pts(sc, workload_type, workload_type_known)
        total += pts
        if pts > 0:
            reasons.append(f"workloadType({workload_type})={pts}")

        pts = get_gpu_points(sc, gpu_count, gpu_count_known)
        total += pts
        if pts > 0 and gpu_count_known:
            reasons.append(f"gpuCount({gpu_count})={pts}")

        pts = get_workload_kind_pts(sc, workload_kind, workload_kind_known)
        total += pts
        if pts > 0 and workload_kind_known:
            reasons.append(f"workloadKind({workload_kind})={pts}")

        pts = get_volume_mount_pts(sc, mount_path, mount_path_known)
        total += pts
        if pts > 0 and mount_path_known:
            reasons.append(f"mountPath({mount_path})={pts}")

        pts = get_framework_pts(sc, fw_cat)
        total += pts
        if pts > 0 and framework_known:
            reasons.append(f"framework({framework}/{fw_cat})={pts}")

        pts = get_read_only_pts(sc, read_only, read_only_known)
        total += pts
        if pts > 0 and read_only_known:
            reasons.append(f"readOnly({read_only})={pts}")

        pts = get_pvc_pts(sc, pvc_count, pvc_count_known)
        total += pts
        if pts > 0 and pvc_count_known:
            reasons.append(f"pvcCount({pvc_count})={pts}")

        pts = get_replica_pts(sc, replicas, replica_known)
        total += pts
        if pts > 0 and replica_known:
            reasons.append(f"replicas({replicas})={pts}")

        scores[sc] = total
        score_reasons[sc] = reasons

    max_score = -1
    top: List[str] = []
    for sc in filtered:
        s = scores[sc]
        if s > max_score:
            max_score = s
            top = [sc]
        elif s == max_score:
            top.append(sc)

    desired_sc = ""
    if workload_type_known:
        if workload_type == "preprocess":
            desired_sc = SC_L1
        elif workload_type == "train":
            desired_sc = SC_L2
        elif workload_type == "infer":
            desired_sc = SC_L3

    chosen = ""
    for sc in top:
        if desired_sc and sc == desired_sc:
            chosen = sc
            break
    if not chosen:
        for sc in top:
            if sc == SC_S3:
                chosen = sc
                break
    if not chosen and top:
        chosen = top[0]

    # 3단계 Hard Rule + AHP Score Rule 분기. 웹훅과 동일한 우선순위:
    #   1) hard_rule_select(tier-hint / archive data-role / cache+조합)
    #   2) score_rule_select(AHP 점수 합산, tie-break L2 > L3 > L1 > S3)
    #   3) 기존 selectStorageClass 호환 시그널이 있으면 legacy score 결과 유지
    #   4) 아무 입력 없으면 default L2
    hard_tier, hard_reason, hard_matched = hard_rule_select(labels, annotations)
    score_tier, score_contribs, ahp_scores, score_has_input = score_rule_select(labels, annotations)
    has_legacy_score_input = (
        workload_type_known
        or framework_known
        or gpu_count_known
        or workload_kind_known
        or mount_path_known
        or read_only_known
        or pvc_count_known
        or replica_known
        or bool(exp_raw)
    )

    selected_tier: str
    tier_reason: str
    if hard_matched:
        selected_tier = hard_tier
        chosen = TIER_TO_SC[selected_tier]
        selection_path = "hard-rule"
        tier_reason = build_tier_reason(selection_path, selected_tier, chosen, ahp_scores, [], hard_reason)
    elif score_has_input:
        selected_tier = score_tier
        chosen = TIER_TO_SC[selected_tier]
        selection_path = "score-rule"
        tier_reason = build_tier_reason(selection_path, selected_tier, chosen, ahp_scores, score_contribs, "")
    elif has_legacy_score_input:
        # 기존 score 로직 chosen 을 그대로 보존(이미 위에서 계산됨).
        selection_path = "score-rule"
        selected_tier = {
            SC_L1: TIER_L1,
            SC_L2: TIER_L2,
            SC_L3: TIER_L3,
            SC_S3: TIER_S3,
        }.get(chosen, TIER_L2)
        tier_reason = build_tier_reason(
            selection_path,
            selected_tier,
            chosen,
            ahp_scores,
            [],
            f"legacy-score(top={top}, maxScore={max_score})",
        )
    else:
        chosen = SC_L2
        selected_tier = TIER_L2
        selection_path = "default-l2"
        tier_reason = build_tier_reason(selection_path, selected_tier, chosen, ahp_scores, [], "no input")

    tier_of = {
        SC_L1: TIER_L1,
        SC_L2: TIER_L2,
        SC_L3: TIER_L3,
        SC_S3: TIER_S3,
    }

    pod_name = os.environ.get("POD_NAME", "?")
    pvc_name = os.environ.get("PVC_NAME", "?")
    ns = os.environ.get("NAMESPACE", "?")
    workload_title = os.environ.get("WORKLOAD_DISPLAY", pod_name)

    print(f"[{workload_title}]")
    print(f"  pod: {pod_name}")
    print(f"  namespace: {ns}, pvc: {pvc_name}")
    print()
    print("  Inputs (from PVC metadata, same as webhook):")
    print(f"    workloadType     = {workload_type or '(empty)'}  (known={workload_type_known})")
    print(f"    gpuCount         = {gpu_count}  (known={gpu_count_known})")
    print(f"    mountPath        = {mount_path or '(empty)'}  (known={mount_path_known})")
    print(f"    framework        = {framework or '(empty)'}  (category={fw_cat or 'n/a'}, known={framework_known})")
    print(f"    workloadKind     = {workload_kind or '(empty)'}  (known={workload_kind_known})")
    print(f"    readOnly         = {read_only}  (known={read_only_known})")
    print(f"    pvcCount         = {pvc_count}  (known={pvc_count_known})")
    print(f"    replicas         = {replicas}  (known={replica_known})")
    print(f"    storage-tier     = {exp_raw or '(empty)'}  (candidate override={'yes' if exp_tier else 'no'})")
    print(f"    accessModes      = {access_modes}")
    print()
    print("[Score results]")
    order = [SC_L1, SC_L2, SC_L3, SC_S3]
    for sc in order:
        if sc in scores:
            short = tier_of[sc]
            print(f"  {short:12} = {scores[sc]:3d}   ({sc})")
    print()
    print(f"  → Selected: {chosen}  (tier: {tier_of.get(chosen, '?')})")
    print(f"  selection-path: {selection_path}")
    print(f"  tier-reason   : {tier_reason}")
    if score_has_input:
        print(f"  AHP scores    : L1={ahp_scores[TIER_L1]}, L2={ahp_scores[TIER_L2]}, "
              f"L3={ahp_scores[TIER_L3]}, S3={ahp_scores[TIER_S3]}")
    if top:
        print(f"  (legacy tie top={top}, maxScore={max_score})")
    print()
    print("  Per-SC breakdown (non-zero contributors):")
    for sc in order:
        if sc not in score_reasons:
            continue
        r = score_reasons[sc]
        if not r:
            continue
        print(f"    {sc}: {', '.join(r)}")


def main() -> None:
    raw = sys.stdin.read()
    if not raw.strip():
        print("ERROR: empty stdin (expected PVC JSON)", file=sys.stderr)
        sys.exit(1)
    pvc = json.loads(raw)
    score_storage_classes(pvc)


if __name__ == "__main__":
    main()
