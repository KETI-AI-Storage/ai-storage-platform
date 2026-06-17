"""
CIFAR-10 전처리 결과를 사용하여 작은 CNN 모델을 학습한다.

GPU가 할당되면 cuda를 사용하고, 테스트 안정성을 위해 GPU가 보이지 않는
환경에서는 cpu로 자동 전환한다.

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
from torch import nn
from torch.utils.data import DataLoader, TensorDataset


class SmallCifarCnn(nn.Module):
    """CIFAR-10 빠른 검증을 위한 작은 CNN 모델이다."""

    def __init__(self) -> None:
        """CNN 계층을 초기화한다."""
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(3, 32, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),
            nn.Conv2d(32, 64, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),
            nn.Conv2d(64, 128, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            nn.AdaptiveAvgPool2d((1, 1)),
        )
        self.classifier = nn.Linear(128, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """입력 이미지를 CIFAR-10 class logit으로 변환한다.

        Args:
            x (torch.Tensor): NCHW 형식의 이미지 tensor.

        Returns:
            torch.Tensor: class별 logit tensor.
        """
        x = self.features(x)
        return self.classifier(torch.flatten(x, 1))


def parse_args() -> argparse.Namespace:
    """학습 실행 인자를 파싱한다.

    Returns:
        argparse.Namespace: 학습 데이터와 checkpoint 경로를 담은 인자 객체.
    """
    parser = argparse.ArgumentParser(description="CIFAR-10 training workload")
    parser.add_argument("--preprocessed-dir", default=os.getenv("PREPROCESSED_DIR", "/data/preprocessed"))
    parser.add_argument("--checkpoint-dir", default=os.getenv("CHECKPOINT_DIR", "/data/checkpoints"))
    parser.add_argument("--log-dir", default=os.getenv("LOG_DIR", "/data/logs"))
    parser.add_argument("--epochs", type=int, default=int(os.getenv("EPOCHS", "2")))
    parser.add_argument("--batch-size", type=int, default=int(os.getenv("BATCH_SIZE", "128")))
    parser.add_argument("--learning-rate", type=float, default=float(os.getenv("LEARNING_RATE", "0.001")))
    parser.add_argument("--max-train-samples", type=int, default=int(os.getenv("MAX_TRAIN_SAMPLES", "10000")))
    return parser.parse_args()


def load_payload(path: Path) -> dict[str, Any]:
    """전처리된 CIFAR-10 tensor 파일을 로드한다.

    Args:
        path (Path): train.pt 또는 test.pt 경로.

    Returns:
        dict[str, Any]: images와 labels를 포함한 payload.

    Raises:
        FileNotFoundError: 전처리 결과 파일이 없을 때 발생한다.
    """
    if not path.exists():
        raise FileNotFoundError(f"전처리 결과가 없습니다: {path}")
    return torch.load(path, map_location="cpu")


def main() -> None:
    """작은 CNN 학습을 수행하고 checkpoint와 summary를 저장한다."""
    args = parse_args()
    preprocessed_dir = Path(args.preprocessed_dir)
    checkpoint_dir = Path(args.checkpoint_dir)
    log_dir = Path(args.log_dir)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    start_time = time.perf_counter()
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    payload = load_payload(preprocessed_dir / "train.pt")
    images = payload["images"][: args.max_train_samples]
    labels = payload["labels"][: args.max_train_samples]
    loader = DataLoader(TensorDataset(images, labels), batch_size=args.batch_size, shuffle=True, num_workers=0)

    model = SmallCifarCnn().to(device)
    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=args.learning_rate)
    history = []

    for epoch in range(1, args.epochs + 1):
        model.train()
        total_loss = 0.0
        total_correct = 0
        total_seen = 0
        for batch_images, batch_labels in loader:
            batch_images = batch_images.to(device, non_blocking=True)
            batch_labels = batch_labels.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            logits = model(batch_images)
            loss = criterion(logits, batch_labels)
            loss.backward()
            optimizer.step()

            batch_size = int(batch_labels.numel())
            total_loss += float(loss.item()) * batch_size
            total_correct += int((logits.argmax(dim=1) == batch_labels).sum().item())
            total_seen += batch_size

        epoch_summary = {
            "epoch": epoch,
            "loss": round(total_loss / max(total_seen, 1), 6),
            "accuracy": round(total_correct / max(total_seen, 1), 6),
            "samples": total_seen,
        }
        history.append(epoch_summary)
        print(json.dumps(epoch_summary, ensure_ascii=False), flush=True)

    checkpoint_path = checkpoint_dir / "cifar10_model.pt"
    torch.save(
        {
            "model_state_dict": model.state_dict(),
            "model_name": "SmallCifarCnn",
            "classes": payload.get("classes"),
            "epochs": args.epochs,
            "history": history,
        },
        checkpoint_path,
    )
    summary = {
        "status": "completed",
        "device": str(device),
        "cuda_available": torch.cuda.is_available(),
        "cuda_device_count": torch.cuda.device_count() if torch.cuda.is_available() else 0,
        "checkpoint_path": str(checkpoint_path),
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "samples": int(labels.numel()),
        "history": history,
        "elapsed_seconds": round(time.perf_counter() - start_time, 3),
    }
    (log_dir / "train_summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
