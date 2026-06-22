from __future__ import annotations
import json, os, time
from pathlib import Path
import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset

class SmallCifarCnn(nn.Module):
    def __init__(self):
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(3, 32, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Conv2d(32, 64, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Conv2d(64, 128, 3, padding=1), nn.ReLU(), nn.AdaptiveAvgPool2d((1, 1)),
        )
        self.classifier = nn.Linear(128, 10)
    def forward(self, x):
        return self.classifier(torch.flatten(self.features(x), 1))

preprocessed_dir = Path(os.getenv("PREPROCESSED_DIR", "/data/preprocessed"))
checkpoint_dir = Path(os.getenv("CHECKPOINT_DIR", "/data/checkpoints"))
result_dir = Path(os.getenv("RESULT_DIR", "/data/results"))
log_dir = Path(os.getenv("LOG_DIR", "/data/logs"))
result_dir.mkdir(parents=True, exist_ok=True)
log_dir.mkdir(parents=True, exist_ok=True)
checkpoint_path = checkpoint_dir / "cifar10_model.pt"
test_path = preprocessed_dir / "test.pt"
if not checkpoint_path.exists():
    raise FileNotFoundError(f"학습 checkpoint가 없습니다. 먼저 training workload를 실행하세요: {checkpoint_path}")
if not test_path.exists():
    raise FileNotFoundError(f"전처리 test 결과가 없습니다: {test_path}")
started = time.perf_counter()
payload = torch.load(test_path, map_location="cpu")
checkpoint = torch.load(checkpoint_path, map_location="cpu")
max_samples = int(os.getenv("MAX_TEST_SAMPLES", "1000"))
images, labels = payload["images"][:max_samples], payload["labels"][:max_samples]
classes = payload.get("classes") or [str(i) for i in range(10)]
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
model = SmallCifarCnn().to(device)
model.load_state_dict(checkpoint["model_state_dict"])
model.eval()
loader = DataLoader(TensorDataset(images, labels), batch_size=int(os.getenv("BATCH_SIZE", "256")), shuffle=False)
predictions, correct, seen = [], 0, 0
with torch.no_grad():
    for batch_images, batch_labels in loader:
        logits = model(batch_images.to(device))
        probs = torch.softmax(logits, 1).cpu()
        pred = probs.argmax(1)
        conf = probs.max(1).values
        correct += int((pred == batch_labels).sum().item())
        seen += int(batch_labels.numel())
        for p, y, c in zip(pred, batch_labels, conf):
            if len(predictions) < 100:
                predictions.append({"predicted_label": classes[int(p)], "actual_label": classes[int(y)], "confidence": round(float(c), 6)})
result = {"samples": seen, "accuracy": round(correct / max(seen, 1), 6), "predictions": predictions}
summary = {"status": "completed", "device": str(device), "result_path": str(result_dir / "inference_results.json"), "accuracy": result["accuracy"], "elapsed_seconds": round(time.perf_counter() - started, 3)}
(result_dir / "inference_results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
(log_dir / "inference_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
print(json.dumps(summary, indent=2), flush=True)
