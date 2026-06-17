"""
학습된 CIFAR-10 checkpoint를 로드하여 test tensor에 대한 추론을 수행한다.

checkpoint가 없으면 명확한 오류 메시지를 출력하고 실패한다.

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
    """학습 workload와 동일한 CIFAR-10 CNN 모델이다."""

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
    """추론 실행 인자를 파싱한다.

    Returns:
        argparse.Namespace: checkpoint와 결과 경로를 담은 인자 객체.
    """
    parser = argparse.ArgumentParser(description="CIFAR-10 inference workload")
    parser.add_argument("--preprocessed-dir", default=os.getenv("PREPROCESSED_DIR", "/data/preprocessed"))
    parser.add_argument("--checkpoint-dir", default=os.getenv("CHECKPOINT_DIR", "/data/checkpoints"))
    parser.add_argument("--result-dir", default=os.getenv("RESULT_DIR", "/data/results"))
    parser.add_argument("--log-dir", default=os.getenv("LOG_DIR", "/data/logs"))
    parser.add_argument("--batch-size", type=int, default=int(os.getenv("BATCH_SIZE", "256")))
    parser.add_argument("--max-test-samples", type=int, default=int(os.getenv("MAX_TEST_SAMPLES", "1000")))
    return parser.parse_args()


def load_payload(path: Path) -> dict[str, Any]:
    """전처리된 CIFAR-10 test tensor 파일을 로드한다.

    Args:
        path (Path): test.pt 경로.

    Returns:
        dict[str, Any]: images와 labels를 포함한 payload.

    Raises:
        FileNotFoundError: test tensor 파일이 없을 때 발생한다.
    """
    if not path.exists():
        raise FileNotFoundError(f"전처리 test 결과가 없습니다: {path}")
    return torch.load(path, map_location="cpu")


def main() -> None:
    """checkpoint 기반 추론을 수행하고 결과 JSON을 저장한다."""
    args = parse_args()
    preprocessed_dir = Path(args.preprocessed_dir)
    checkpoint_dir = Path(args.checkpoint_dir)
    result_dir = Path(args.result_dir)
    log_dir = Path(args.log_dir)
    result_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    checkpoint_path = checkpoint_dir / "cifar10_model.pt"
    if not checkpoint_path.exists():
        raise FileNotFoundError(f"학습 checkpoint가 없습니다. 먼저 training workload를 실행하세요: {checkpoint_path}")

    start_time = time.perf_counter()
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    payload = load_payload(preprocessed_dir / "test.pt")
    images = payload["images"][: args.max_test_samples]
    labels = payload["labels"][: args.max_test_samples]
    classes = payload.get("classes") or [str(index) for index in range(10)]
    loader = DataLoader(TensorDataset(images, labels), batch_size=args.batch_size, shuffle=False, num_workers=0)

    model = SmallCifarCnn().to(device)
    checkpoint = torch.load(checkpoint_path, map_location=device)
    model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()

    predictions = []
    total_correct = 0
    total_seen = 0
    with torch.no_grad():
        for batch_images, batch_labels in loader:
            batch_images = batch_images.to(device, non_blocking=True)
            logits = model(batch_images)
            probs = torch.softmax(logits, dim=1)
            batch_predictions = probs.argmax(dim=1).cpu()
            batch_confidence = probs.max(dim=1).values.cpu()
            for predicted, actual, confidence in zip(batch_predictions, batch_labels, batch_confidence):
                predictions.append(
                    {
                        "predicted_index": int(predicted.item()),
                        "predicted_label": classes[int(predicted.item())],
                        "actual_index": int(actual.item()),
                        "actual_label": classes[int(actual.item())],
                        "confidence": round(float(confidence.item()), 6),
                    }
                )
            total_correct += int((batch_predictions == batch_labels).sum().item())
            total_seen += int(batch_labels.numel())

    result = {
        "checkpoint_path": str(checkpoint_path),
        "samples": total_seen,
        "accuracy": round(total_correct / max(total_seen, 1), 6),
        "predictions": predictions[:100],
    }
    summary = {
        "status": "completed",
        "device": str(device),
        "cuda_available": torch.cuda.is_available(),
        "cuda_device_count": torch.cuda.device_count() if torch.cuda.is_available() else 0,
        "checkpoint_path": str(checkpoint_path),
        "result_path": str(result_dir / "inference_results.json"),
        "samples": total_seen,
        "accuracy": result["accuracy"],
        "elapsed_seconds": round(time.perf_counter() - start_time, 3),
    }
    (result_dir / "inference_results.json").write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    (log_dir / "inference_summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
