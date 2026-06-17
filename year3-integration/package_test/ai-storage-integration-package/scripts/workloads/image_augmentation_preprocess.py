"""
CIFAR-10 전처리 tensor를 읽어 학습용 augmentation을 미리 적용한 캐시를 생성한다.

random crop, horizontal flip, normalization을 N epoch 분량 반복 적용하여
augmented_train.pt 단일 파일로 직렬화한다. 결과 캐시는 학습 단계에서
ultra-low latency tier에서 반복 접근되는 것을 가정한다.

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
import torch.nn.functional as F


def parse_args() -> argparse.Namespace:
    """augmentation 캐시 생성에 필요한 실행 인자를 파싱한다.

    Returns:
        argparse.Namespace: 입력/출력 경로와 augmentation 파라미터.
    """
    parser = argparse.ArgumentParser(description="Image augmentation preprocessing workload")
    parser.add_argument("--input-path", default=os.getenv("INPUT_PATH", "/data/preprocessed/train.pt"))
    parser.add_argument("--augmented-dir", default=os.getenv("AUGMENTED_DIR", "/data/augmented"))
    parser.add_argument("--log-dir", default=os.getenv("LOG_DIR", "/data/logs"))
    parser.add_argument("--passes", type=int, default=int(os.getenv("AUGMENT_PASSES", "3")))
    parser.add_argument("--crop-padding", type=int, default=int(os.getenv("CROP_PADDING", "4")))
    parser.add_argument("--flip-prob", type=float, default=float(os.getenv("FLIP_PROB", "0.5")))
    parser.add_argument("--fallback-samples", type=int, default=int(os.getenv("FALLBACK_SAMPLES", "1024")))
    return parser.parse_args()


def ensure_dirs(*paths: Path) -> None:
    """필요한 출력 디렉터리를 멱등적으로 생성한다.

    Args:
        *paths (Path): 생성할 디렉터리 경로 목록.
    """
    for path in paths:
        path.mkdir(parents=True, exist_ok=True)


def load_or_synthesize(input_path: Path, fallback_samples: int) -> dict[str, Any]:
    """train.pt가 있으면 로드하고, 없으면 동일 shape의 더미 텐서를 생성한다.

    Args:
        input_path (Path): 전처리 결과 tensor 경로.
        fallback_samples (int): 입력 파일이 없을 때 생성할 샘플 수.

    Returns:
        dict[str, Any]: images, labels, classes 키를 포함하는 payload.
    """
    if input_path.exists():
        # 학습용 train.pt를 그대로 사용 → preprocessing 결과 PVC를 large-read 패턴으로 소비.
        payload = torch.load(input_path, map_location="cpu")
        return payload

    # 폐쇄망 또는 단독 실행 시 CIFAR-10 형태(3x32x32)에 맞는 임시 텐서를 만든다.
    images = torch.rand(fallback_samples, 3, 32, 32)
    labels = torch.randint(low=0, high=10, size=(fallback_samples,), dtype=torch.long)
    return {
        "images": images,
        "labels": labels,
        "classes": [f"class_{i}" for i in range(10)],
    }


def random_crop_with_padding(images: torch.Tensor, padding: int) -> torch.Tensor:
    """zero padding 후 원본 크기로 random crop을 수행한다.

    Args:
        images (torch.Tensor): NCHW 형식 이미지 배치.
        padding (int): 각 변에 추가할 zero padding 크기.

    Returns:
        torch.Tensor: 원본과 동일한 NCHW 크기의 crop 결과.
    """
    if padding <= 0:
        return images
    padded = F.pad(images, [padding] * 4, mode="constant", value=0.0)
    _, _, h, w = images.shape
    top = torch.randint(0, padded.shape[2] - h + 1, (1,)).item()
    left = torch.randint(0, padded.shape[3] - w + 1, (1,)).item()
    return padded[:, :, top : top + h, left : left + w]


def random_horizontal_flip(images: torch.Tensor, prob: float) -> torch.Tensor:
    """확률 prob로 horizontal flip을 적용한다.

    Args:
        images (torch.Tensor): NCHW 이미지 배치.
        prob (float): 0~1 범위의 flip 확률.

    Returns:
        torch.Tensor: flip 결과 (확률에 따라 원본 그대로일 수 있음).
    """
    if prob <= 0:
        return images
    mask = torch.rand(images.shape[0]) < prob
    if not mask.any():
        return images
    flipped = images.clone()
    flipped[mask] = torch.flip(images[mask], dims=[-1])
    return flipped


def normalize(images: torch.Tensor) -> torch.Tensor:
    """CIFAR-10 통계로 channel-wise normalization을 수행한다.

    Args:
        images (torch.Tensor): NCHW 이미지 배치 (값 범위 [0, 1] 가정).

    Returns:
        torch.Tensor: normalize된 NCHW 텐서.
    """
    mean = torch.tensor([0.4914, 0.4822, 0.4465]).view(1, 3, 1, 1)
    std = torch.tensor([0.2470, 0.2435, 0.2616]).view(1, 3, 1, 1)
    return (images - mean) / std


def main() -> None:
    """train.pt를 다중 epoch augmentation하여 augmented_train.pt 캐시를 생성한다."""
    args = parse_args()
    input_path = Path(args.input_path)
    augmented_dir = Path(args.augmented_dir)
    log_dir = Path(args.log_dir)
    ensure_dirs(augmented_dir, log_dir)

    started = time.perf_counter()
    payload = load_or_synthesize(input_path, args.fallback_samples)
    base_images = payload["images"].float()
    labels = payload["labels"]
    classes = payload.get("classes", [])

    if base_images.max() > 1.5:
        # 원본이 [0,255]로 들어온 경우 정규화 입력 범위를 맞춘다.
        base_images = base_images / 255.0

    augmented_chunks = []
    label_chunks = []
    for epoch_idx in range(max(1, args.passes)):
        # WHY: 캐시 PVC(L1)에 N pass 분량의 augmented sample을 미리 적재하여
        #      학습 단계가 repeated-access pattern으로 ultra-low latency tier를 활용한다.
        images = random_crop_with_padding(base_images, args.crop_padding)
        images = random_horizontal_flip(images, args.flip_prob)
        images = normalize(images)
        augmented_chunks.append(images)
        label_chunks.append(labels)
        print(
            f"augment pass={epoch_idx} samples={images.shape[0]} shape={list(images.shape)}",
            flush=True,
        )

    augmented_images = torch.cat(augmented_chunks, dim=0)
    augmented_labels = torch.cat(label_chunks, dim=0)
    output_path = augmented_dir / "augmented_train.pt"
    torch.save(
        {
            "images": augmented_images,
            "labels": augmented_labels,
            "classes": classes,
            "augmentation": {
                "crop_padding": args.crop_padding,
                "flip_prob": args.flip_prob,
                "passes": args.passes,
                "normalize_mean": [0.4914, 0.4822, 0.4465],
                "normalize_std": [0.2470, 0.2435, 0.2616],
            },
        },
        output_path,
    )

    summary = {
        "status": "completed",
        "input_path": str(input_path),
        "input_existed": input_path.exists(),
        "augmented_path": str(output_path),
        "augmented_samples": int(augmented_images.shape[0]),
        "augmented_shape": list(augmented_images.shape),
        "passes": args.passes,
        "crop_padding": args.crop_padding,
        "flip_prob": args.flip_prob,
        "torch_version": torch.__version__,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }
    summary_path = log_dir / "augmentation_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
