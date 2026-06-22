from __future__ import annotations
import json, os, time
from pathlib import Path
import torch
from torch.utils.data import Subset
from torchvision import datasets, transforms

def flag(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "y", "on"}

def dump_dataset(dataset, max_samples: int):
    subset = Subset(dataset, range(min(len(dataset), max_samples)))
    images, labels = [], []
    for image, label in subset:
        images.append(image)
        labels.append(label)
    return {"images": torch.stack(images), "labels": torch.tensor(labels), "classes": dataset.classes}

raw_dir = Path(os.getenv("RAW_DIR", "/data/raw"))
output_dir = Path(os.getenv("PREPROCESSED_DIR", "/data/preprocessed"))
cache_dir = Path(os.getenv("CACHE_DIR", "/data/cache"))
log_dir = Path(os.getenv("LOG_DIR", "/data/logs"))
for path in (raw_dir, output_dir, cache_dir, log_dir):
    path.mkdir(parents=True, exist_ok=True)

started = time.perf_counter()
transform = transforms.Compose([
    transforms.Resize((int(os.getenv("IMAGE_SIZE", "32")), int(os.getenv("IMAGE_SIZE", "32")))),
    transforms.ToTensor(),
    transforms.Normalize((0.4914, 0.4822, 0.4465), (0.2470, 0.2435, 0.2616)),
])
download = flag(os.getenv("CIFAR10_DOWNLOAD", "true"))
train = datasets.CIFAR10(str(raw_dir), train=True, download=download, transform=transform)
test = datasets.CIFAR10(str(raw_dir), train=False, download=download, transform=transform)
train_payload = dump_dataset(train, int(os.getenv("MAX_TRAIN_SAMPLES", "50000")))
test_payload = dump_dataset(test, int(os.getenv("MAX_TEST_SAMPLES", "10000")))
torch.save(train_payload, output_dir / "train.pt")
torch.save(test_payload, output_dir / "test.pt")
summary = {
    "status": "completed",
    "download": download,
    "train_path": str(output_dir / "train.pt"),
    "test_path": str(output_dir / "test.pt"),
    "train_samples": int(train_payload["labels"].numel()),
    "test_samples": int(test_payload["labels"].numel()),
    "elapsed_seconds": round(time.perf_counter() - started, 3),
}
(log_dir / "preprocess_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
print(json.dumps(summary, indent=2), flush=True)
