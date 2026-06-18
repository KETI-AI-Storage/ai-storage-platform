"""PyTorch GPU training pipeline (reference).

A small CNN trained on a synthetic image-classification task so the job is
self-contained (no dataset download). Uses CUDA when available. Replace
`make_dataset` and the model with your real data/model — the build -> Docker Hub
-> ArgoCD GPU Job pipeline stays the same.
"""
import json
import os
import time

import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset


def make_dataset(n, img=32, ch=3, classes=10, seed=0):
    g = torch.Generator().manual_seed(seed)
    protos = torch.randn(classes, ch, img, img, generator=g)
    y = torch.randint(0, classes, (n,), generator=g)
    x = protos[y] + 0.8 * torch.randn(n, ch, img, img, generator=g)
    return TensorDataset(x, y)


class CNN(nn.Module):
    def __init__(self, ch=3, classes=10):
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(ch, 32, 3, padding=1), nn.BatchNorm2d(32), nn.ReLU(), nn.MaxPool2d(2),
            nn.Conv2d(32, 64, 3, padding=1), nn.BatchNorm2d(64), nn.ReLU(), nn.MaxPool2d(2),
            nn.Conv2d(64, 128, 3, padding=1), nn.BatchNorm2d(128), nn.ReLU(), nn.AdaptiveAvgPool2d(1),
        )
        self.classifier = nn.Linear(128, classes)

    def forward(self, x):
        return self.classifier(self.features(x).flatten(1))


def main():
    epochs = int(os.getenv("EPOCHS", "10"))
    batch = int(os.getenv("BATCH_SIZE", "256"))
    lr = float(os.getenv("LR", "0.001"))
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"[train] torch={torch.__version__} cuda={torch.cuda.is_available()} device={device}", flush=True)
    if device == "cuda":
        p = torch.cuda.get_device_properties(0)
        print(f"[train] GPU={p.name} mem={p.total_memory/1e9:.0f}GB cc=sm_{p.major}{p.minor} "
              f"count={torch.cuda.device_count()}", flush=True)
    else:
        print("[train] WARNING: no GPU visible, running on CPU", flush=True)

    train_dl = DataLoader(make_dataset(10000, seed=1), batch_size=batch, shuffle=True,
                          num_workers=2, pin_memory=(device == "cuda"))
    xt, yt = make_dataset(2000, seed=2).tensors
    xt, yt = xt.to(device), yt.to(device)

    model = CNN().to(device)
    opt = torch.optim.Adam(model.parameters(), lr=lr)
    lossf = nn.CrossEntropyLoss()
    use_amp = (device == "cuda")
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)

    t0, acc = time.time(), 0.0
    for ep in range(1, epochs + 1):
        model.train()
        total, count = 0.0, 0
        for x, y in train_dl:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
            opt.zero_grad()
            with torch.autocast(device_type=device, enabled=use_amp):
                loss = lossf(model(x), y)
            scaler.scale(loss).backward()
            scaler.step(opt)
            scaler.update()
            total += loss.item() * len(y)
            count += len(y)
        model.eval()
        with torch.no_grad():
            acc = (model(xt).argmax(1) == yt).float().mean().item()
        mem = torch.cuda.max_memory_allocated() / 1e9 if device == "cuda" else 0.0
        print(f"[train] epoch {ep}/{epochs} loss={total/count:.4f} test_acc={acc:.3f} "
              f"gpu_mem={mem:.2f}GB ({time.time()-t0:.1f}s)", flush=True)

    out_dir = os.getenv("OUTPUT_DIR", "/data")
    metrics = {"final_acc": round(acc, 4), "epochs": epochs, "device": device,
               "params": sum(p.numel() for p in model.parameters())}
    print(f"[train] DONE metrics={json.dumps(metrics)}", flush=True)
    try:
        os.makedirs(out_dir, exist_ok=True)
        torch.save(model.state_dict(), os.path.join(out_dir, "model.pt"))
        json.dump(metrics, open(os.path.join(out_dir, "metrics.json"), "w"))
        print(f"[train] saved checkpoint -> {out_dir}/model.pt", flush=True)
    except OSError as e:
        print(f"[train] no writable output dir ({e})", flush=True)


if __name__ == "__main__":
    main()
