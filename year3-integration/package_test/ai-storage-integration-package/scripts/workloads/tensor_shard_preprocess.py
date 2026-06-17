"""
대용량 train.pt를 일정 크기 shard 파일로 나누어 저장한다.

학습 분산 로딩을 위해 shard-000.pt ~ shard-NNN.pt를 생성한다.
입력은 preprocessing-input(L2), 출력은 intermediate large-write(L3) 패턴을
가정한다.

Author: 미정 <unknown@example.com>
Created: 2026-05-28
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any

import torch


def parse_args() -> argparse.Namespace:
    """tensor shard 분할에 필요한 실행 인자를 파싱한다.

    Returns:
        argparse.Namespace: 입력/출력 경로와 shard 개수, 더미 텐서 옵션.
    """
    parser = argparse.ArgumentParser(description="Tensor shard preprocessing workload")
    parser.add_argument("--input-path", default=os.getenv("INPUT_PATH", "/data/preprocessed/train.pt"))
    parser.add_argument("--shards-dir", default=os.getenv("SHARDS_DIR", "/data/shards"))
    parser.add_argument("--log-dir", default=os.getenv("LOG_DIR", "/data/logs"))
    parser.add_argument("--num-shards", type=int, default=int(os.getenv("NUM_SHARDS", "16")))
    parser.add_argument("--fallback-samples", type=int, default=int(os.getenv("FALLBACK_SAMPLES", "4096")))
    parser.add_argument("--fallback-feature-dim", type=int, default=int(os.getenv("FALLBACK_FEATURE_DIM", "256")))
    return parser.parse_args()


def ensure_dirs(*paths: Path) -> None:
    """필요한 출력 디렉터리를 멱등적으로 생성한다.

    Args:
        *paths (Path): 생성할 디렉터리 경로 목록.
    """
    for path in paths:
        path.mkdir(parents=True, exist_ok=True)


def load_or_synthesize(input_path: Path, fallback_samples: int, fallback_feature_dim: int) -> dict[str, Any]:
    """train.pt가 있으면 로드하고, 없으면 (N, F) 형태의 더미 텐서를 만든다.

    Args:
        input_path (Path): preprocessing 결과 텐서 경로.
        fallback_samples (int): 합성 시 샘플 수.
        fallback_feature_dim (int): 합성 시 feature 차원.

    Returns:
        dict[str, Any]: tensor를 가진 payload dict (images/labels 또는 features/labels 키).
    """
    if input_path.exists():
        return torch.load(input_path, map_location="cpu")
    # 폐쇄망 또는 단독 실행 시 large-read 패턴을 흉내내기 위한 큰 합성 텐서.
    return {
        "features": torch.randn(fallback_samples, fallback_feature_dim),
        "labels": torch.randint(0, 10, (fallback_samples,), dtype=torch.long),
        "classes": [f"class_{i}" for i in range(10)],
    }


def extract_tensor_view(payload: dict[str, Any]) -> tuple[torch.Tensor, torch.Tensor, list[str]]:
    """payload에서 (features tensor, labels tensor, classes)를 통일된 형태로 추출한다.

    Args:
        payload (dict[str, Any]): images/labels 또는 features/labels 키를 가진 dict.

    Returns:
        tuple[torch.Tensor, torch.Tensor, list[str]]: 텐서와 클래스 메타데이터.

    Raises:
        KeyError: features/images 키가 모두 없는 경우.
    """
    if "features" in payload:
        features = payload["features"]
    elif "images" in payload:
        features = payload["images"]
    else:
        raise KeyError("payload must contain 'features' or 'images'")
    labels = payload.get("labels", torch.zeros(features.shape[0], dtype=torch.long))
    classes = payload.get("classes", [])
    return features, labels, classes


def main() -> None:
    """train.pt를 N 개 shard로 분할 저장하고 summary를 기록한다."""
    args = parse_args()
    input_path = Path(args.input_path)
    shards_dir = Path(args.shards_dir)
    log_dir = Path(args.log_dir)
    ensure_dirs(shards_dir, log_dir)

    started = time.perf_counter()
    payload = load_or_synthesize(input_path, args.fallback_samples, args.fallback_feature_dim)
    features, labels, classes = extract_tensor_view(payload)
    total_samples = int(features.shape[0])
    num_shards = max(1, args.num_shards)
    # WHY: 마지막 shard에 잔여 sample을 모두 몰아넣어 sample 수가 num_shards로
    #      나누어 떨어지지 않아도 유실되지 않도록 한다.
    base_shard_size = total_samples // num_shards
    remainder = total_samples - base_shard_size * num_shards

    shard_records = []
    cursor = 0
    for shard_index in range(num_shards):
        extra = 1 if shard_index < remainder else 0
        size = base_shard_size + extra
        if size == 0:
            # num_shards가 total_samples보다 크면 빈 shard는 건너뛰고 종료한다.
            break
        slice_features = features[cursor : cursor + size]
        slice_labels = labels[cursor : cursor + size]
        cursor += size
        shard_path = shards_dir / f"shard-{shard_index:03d}.pt"
        torch.save(
            {
                "features": slice_features,
                "labels": slice_labels,
                "shard_index": shard_index,
                "num_shards": num_shards,
            },
            shard_path,
        )
        shard_records.append(
            {
                "index": shard_index,
                "path": str(shard_path),
                "samples": int(slice_features.shape[0]),
                "shape": list(slice_features.shape),
                "bytes": int(slice_features.element_size() * slice_features.numel()),
            }
        )
        print(
            f"shard {shard_index} saved samples={slice_features.shape[0]} shape={list(slice_features.shape)}",
            flush=True,
        )

    summary = {
        "status": "completed",
        "input_path": str(input_path),
        "input_existed": input_path.exists(),
        "shards_dir": str(shards_dir),
        "num_shards_requested": num_shards,
        "num_shards_written": len(shard_records),
        "total_samples": total_samples,
        "classes_known": len(classes),
        "shards": shard_records,
        "torch_version": torch.__version__,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }
    summary_path = log_dir / "tensor_shard_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
