"""
PyTorch checkpoint read/write 부하를 생성하여 스토리지 I/O를 검증한다.

GPU 없이 실행되며 checkpoint PVC의 쓰기와 읽기 성능을 별도로 관찰한다.

Author: 미정 <unknown@example.com>
Created: 2026-05-27
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

import torch


def parse_args() -> argparse.Namespace:
    """checkpoint I/O 실행 인자를 파싱한다.

    Returns:
        argparse.Namespace: 반복 횟수와 tensor 크기를 담은 인자 객체.
    """
    parser = argparse.ArgumentParser(description="PyTorch checkpoint I/O workload")
    parser.add_argument("--checkpoint-dir", default=os.getenv("CHECKPOINT_DIR", "/data/checkpoints"))
    parser.add_argument("--log-dir", default=os.getenv("LOG_DIR", "/data/logs"))
    parser.add_argument("--iterations", type=int, default=int(os.getenv("ITERATIONS", "8")))
    parser.add_argument("--tensor-mb", type=int, default=int(os.getenv("TENSOR_MB", "64")))
    return parser.parse_args()


def make_payload(tensor_mb: int, iteration: int) -> dict[str, torch.Tensor | int]:
    """지정한 크기의 checkpoint payload를 생성한다.

    Args:
        tensor_mb (int): 생성할 tensor 크기(MiB).
        iteration (int): checkpoint 반복 번호.

    Returns:
        dict[str, torch.Tensor | int]: 저장할 tensor와 metadata.
    """
    element_count = tensor_mb * 1024 * 1024 // 4
    tensor = torch.randn(element_count, dtype=torch.float32)
    return {"iteration": iteration, "tensor": tensor}


def main() -> None:
    """checkpoint 반복 저장과 로드를 수행하고 summary를 저장한다."""
    args = parse_args()
    checkpoint_dir = Path(args.checkpoint_dir)
    log_dir = Path(args.log_dir)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    start_time = time.perf_counter()
    write_seconds = 0.0
    read_seconds = 0.0
    paths = []

    for iteration in range(args.iterations):
        path = checkpoint_dir / f"io_test_{iteration:03d}.pt"
        payload = make_payload(args.tensor_mb, iteration)

        write_start = time.perf_counter()
        torch.save(payload, path)
        write_seconds += time.perf_counter() - write_start

        read_start = time.perf_counter()
        loaded = torch.load(path, map_location="cpu")
        read_seconds += time.perf_counter() - read_start

        checksum = float(loaded["tensor"][:1024].sum().item())
        paths.append(str(path))
        print(f"io iteration={iteration} path={path} checksum={checksum:.6f}", flush=True)

    total_mb = args.iterations * args.tensor_mb
    summary = {
        "status": "completed",
        "iterations": args.iterations,
        "tensor_mb": args.tensor_mb,
        "total_write_mb": total_mb,
        "total_read_mb": total_mb,
        "write_seconds": round(write_seconds, 3),
        "read_seconds": round(read_seconds, 3),
        "elapsed_seconds": round(time.perf_counter() - start_time, 3),
        "paths": paths,
    }
    (log_dir / "checkpoint_io_summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
