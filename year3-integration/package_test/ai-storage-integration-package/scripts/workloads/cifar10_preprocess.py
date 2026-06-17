"""
CIFAR-10 원본 데이터를 전처리하여 학습용 tensor 파일로 저장한다.

폐쇄망에서는 /data/raw에 미리 준비된 CIFAR-10 파일을 사용하고,
온라인 환경에서는 torchvision이 원본 데이터를 다운로드할 수 있다.

Author: 미정 <unknown@example.com>
Created: 2026-05-27
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any

import torch
from torch.utils.data import Subset
from torchvision import datasets, transforms


def str_to_bool(value: str) -> bool:
    """문자열 환경변수를 boolean 값으로 변환한다.

    Args:
        value (str): true/false 계열 문자열.

    Returns:
        bool: 참 또는 거짓 변환 결과.
    """
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def parse_args() -> argparse.Namespace:
    """CIFAR-10 전처리 실행 인자를 파싱한다.

    Returns:
        argparse.Namespace: 전처리 경로와 샘플 제한을 담은 인자 객체.
    """
    parser = argparse.ArgumentParser(description="CIFAR-10 preprocessing workload")
    parser.add_argument("--raw-dir", default=os.getenv("RAW_DIR", "/data/raw"))
    parser.add_argument("--output-dir", default=os.getenv("PREPROCESSED_DIR", "/data/preprocessed"))
    parser.add_argument("--cache-dir", default=os.getenv("CACHE_DIR", "/data/cache"))
    parser.add_argument("--log-dir", default=os.getenv("LOG_DIR", "/data/logs"))
    parser.add_argument("--download", default=os.getenv("CIFAR10_DOWNLOAD", "true"))
    parser.add_argument("--image-size", type=int, default=int(os.getenv("IMAGE_SIZE", "32")))
    parser.add_argument("--max-train-samples", type=int, default=int(os.getenv("MAX_TRAIN_SAMPLES", "50000")))
    parser.add_argument("--max-test-samples", type=int, default=int(os.getenv("MAX_TEST_SAMPLES", "10000")))
    return parser.parse_args()


def ensure_dirs(*paths: Path) -> None:
    """필요한 출력 디렉터리를 생성한다.

    Args:
        *paths (Path): 생성할 디렉터리 경로 목록.
    """
    for path in paths:
        path.mkdir(parents=True, exist_ok=True)


def materialize_dataset(dataset: Any, max_samples: int) -> dict[str, Any]:
    """torchvision dataset을 tensor 묶음으로 변환한다.

    Args:
        dataset (Any): CIFAR-10 dataset 객체.
        max_samples (int): 저장할 최대 샘플 수.

    Returns:
        dict[str, Any]: images, labels, classes를 포함한 저장 객체.
    """
    sample_count = min(len(dataset), max_samples)
    subset = Subset(dataset, range(sample_count))
    images = []
    labels = []
    for image, label in subset:
        images.append(image)
        labels.append(label)
    return {
        "images": torch.stack(images),
        "labels": torch.tensor(labels, dtype=torch.long),
        "classes": dataset.classes,
    }


def main() -> None:
    """CIFAR-10 다운로드와 전처리 저장 절차를 실행한다."""
    args = parse_args()
    raw_dir = Path(args.raw_dir)
    output_dir = Path(args.output_dir)
    cache_dir = Path(args.cache_dir)
    log_dir = Path(args.log_dir)
    ensure_dirs(raw_dir, output_dir, cache_dir, log_dir)

    start_time = time.perf_counter()
    download = str_to_bool(args.download)
    transform = transforms.Compose(
        [
            transforms.Resize((args.image_size, args.image_size)),
            transforms.ToTensor(),
            transforms.Normalize((0.4914, 0.4822, 0.4465), (0.2470, 0.2435, 0.2616)),
        ]
    )

    print(f"preprocess raw_dir={raw_dir} download={download}", flush=True)
    train_dataset = datasets.CIFAR10(root=str(raw_dir), train=True, download=download, transform=transform)
    test_dataset = datasets.CIFAR10(root=str(raw_dir), train=False, download=download, transform=transform)

    train_payload = materialize_dataset(train_dataset, args.max_train_samples)
    test_payload = materialize_dataset(test_dataset, args.max_test_samples)

    train_path = output_dir / "train.pt"
    test_path = output_dir / "test.pt"
    torch.save(train_payload, train_path)
    torch.save(test_payload, test_path)

    summary = {
        "status": "completed",
        "raw_dir": str(raw_dir),
        "output_dir": str(output_dir),
        "cache_dir": str(cache_dir),
        "download": download,
        "image_size": args.image_size,
        "train_samples": int(train_payload["labels"].numel()),
        "test_samples": int(test_payload["labels"].numel()),
        "train_path": str(train_path),
        "test_path": str(test_path),
        "torch_version": torch.__version__,
        "elapsed_seconds": round(time.perf_counter() - start_time, 3),
    }
    summary_path = log_dir / "preprocess_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
