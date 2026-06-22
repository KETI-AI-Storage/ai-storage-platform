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
log_dir = Path(os.getenv("LOG_DIR", "/data/logs"))
checkpoint_dir.mkdir(parents=True, exist_ok=True)
log_dir.mkdir(parents=True, exist_ok=True)
train_path = preprocessed_dir / "train.pt"
if not train_path.exists():
    raise FileNotFoundError(f"전처리 결과가 없습니다: {train_path}")
started = time.perf_counter()
payload = torch.load(train_path, map_location="cpu")
max_samples = int(os.getenv("MAX_TRAIN_SAMPLES", "10000"))
images, labels = payload["images"][:max_samples], payload["labels"][:max_samples]
loader = DataLoader(TensorDataset(images, labels), batch_size=int(os.getenv("BATCH_SIZE", "128")), shuffle=True)
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
model = SmallCifarCnn().to(device)
optimizer = torch.optim.Adam(model.parameters(), lr=float(os.getenv("LEARNING_RATE", "0.001")))
criterion = nn.CrossEntropyLoss()
history = []
for epoch in range(1, int(os.getenv("EPOCHS", "2")) + 1):
    total_loss = total_correct = total_seen = 0
    model.train()
    for batch_images, batch_labels in loader:
        batch_images, batch_labels = batch_images.to(device), batch_labels.to(device)
        optimizer.zero_grad(set_to_none=True)
        logits = model(batch_images)
        loss = criterion(logits, batch_labels)
        loss.backward()
        optimizer.step()
        seen = int(batch_labels.numel())
        total_loss += float(loss.item()) * seen
        total_correct += int((logits.argmax(1) == batch_labels).sum().item())
        total_seen += seen
    item = {"epoch": epoch, "loss": round(total_loss / total_seen, 6), "accuracy": round(total_correct / total_seen, 6)}
    history.append(item)
    print(json.dumps(item), flush=True)
checkpoint_path = checkpoint_dir / "cifar10_model.pt"
torch.save({"model_state_dict": model.state_dict(), "classes": payload.get("classes"), "history": history}, checkpoint_path)
summary = {
    "status": "completed",
    "device": str(device),
    "checkpoint_path": str(checkpoint_path),
    "samples": int(labels.numel()),
    "history": history,
    "elapsed_seconds": round(time.perf_counter() - started, 3),
}
(log_dir / "train_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
print(json.dumps(summary, indent=2), flush=True)
