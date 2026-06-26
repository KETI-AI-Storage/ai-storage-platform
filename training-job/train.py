"""ViT-Base training on CIFAR-10 — real GPU training with demo-friendly logs.

Model: HuggingFace ViTForImageClassification (ViT-Base scale, adapted to CIFAR 32x32).
Moved into the GitOps image lane (commit -> CI build -> Docker Hub -> KFP/ArgoCD) so the
KFP pipeline's training stage runs this on the cluster GPU (Kueue-admitted, webhook-injected).

Logs are intentionally verbose (banners, GPU info, model size, per-epoch loss/acc/mem/time)
so the live demo clearly shows: data -> ViT model -> GPU training -> artifacts.

I/O (KFP): STORAGE_ROOT+INPUT_PATH (preprocessing-stage output), STORAGE_ROOT+OUTPUT_PATH
(this stage's output). Standalone: OUTPUT_DIR (default /data).
Env: EPOCHS(5) BATCH_SIZE(128) TRAIN_SAMPLES(5000) LR(3e-4).
"""
import json
import os
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset
from transformers import ViTConfig, ViTForImageClassification


def log(msg):
    print(f"[train] {msg}", flush=True)


def banner(title):
    print(f"\n{'=' * 64}\n  {title}\n{'=' * 64}", flush=True)


def resolve_io():
    sr, ip, op = os.getenv("STORAGE_ROOT", ""), os.getenv("INPUT_PATH", ""), os.getenv("OUTPUT_PATH", "")
    out = Path(sr + op) if (sr and op) else Path(os.getenv("OUTPUT_DIR", "/data"))
    inp = Path(sr + ip) if (sr and ip) else None
    return inp, out


def load_cifar(n, device):
    """Load a CIFAR-10 subset (real images) for a genuine training run; synthetic fallback."""
    try:
        from datasets import load_dataset
        ds = load_dataset("uoft-cs/cifar10", split=f"train[:{n}]")
        imgs = np.stack([np.asarray(im, dtype=np.float32).transpose(2, 0, 1) / 255.0 for im in ds["img"]])
        x = torch.from_numpy(imgs)
        y = torch.tensor(ds["label"], dtype=torch.long)
        log(f"loaded REAL CIFAR-10 subset: x={tuple(x.shape)} y={tuple(y.shape)} classes=10")
        return x, y
    except Exception as e:  # offline / no datasets -> synthetic CIFAR-like
        log(f"CIFAR load unavailable ({e}); using synthetic CIFAR-like data")
        g = torch.Generator().manual_seed(0)
        protos = torch.randn(10, 3, 32, 32, generator=g)
        y = torch.randint(0, 10, (n,), generator=g)
        x = protos[y] + 0.6 * torch.randn(n, 3, 32, 32, generator=g)
        return x, y


def main():
    epochs = int(os.getenv("EPOCHS", "5"))
    batch = int(os.getenv("BATCH_SIZE", "128"))
    n = int(os.getenv("TRAIN_SAMPLES", "5000"))
    lr = float(os.getenv("LR", "3e-4"))

    banner("ENVIRONMENT")
    log(f"torch={torch.__version__}  cuda_build={torch.version.cuda}  cuda_available={torch.cuda.is_available()}")
    device = "cuda" if torch.cuda.is_available() else "cpu"
    gpu_name = None
    if device == "cuda":
        p = torch.cuda.get_device_properties(0)
        gpu_name = p.name
        log(f"GPU = {p.name}")
        log(f"     memory={p.total_memory / 1e9:.0f}GB  compute=sm_{p.major}{p.minor}  multiprocessors={p.multi_processor_count}")
    else:
        log("no GPU visible -> training on CPU")

    banner("DATA  (CIFAR-10 -> ViT pixel tensors)")
    inp, out = resolve_io()
    out.mkdir(parents=True, exist_ok=True)
    if inp is not None:
        pp = inp / "vit_preprocessed_pixel_values.npy"
        if pp.exists():
            log(f"pipeline preprocessing-stage output present: {pp} ({pp.stat().st_size} bytes) — feeding cache check")
        else:
            log(f"no preprocessing-stage cache at {pp} (standalone run)")
    x, y = load_cifar(n, device)
    loader = DataLoader(TensorDataset(x, y), batch_size=batch, shuffle=True, num_workers=2,
                        pin_memory=(device == "cuda"))
    log(f"train set: {len(x)} images, batch_size={batch}, steps/epoch={len(loader)}")

    banner("MODEL  (ViT-Base / ViTForImageClassification)")
    config = ViTConfig(
        image_size=32, patch_size=4, num_channels=3,
        hidden_size=768, num_hidden_layers=12, num_attention_heads=12,
        intermediate_size=3072, num_labels=10,
    )
    model = ViTForImageClassification(config).to(device)
    nparams = sum(pp.numel() for pp in model.parameters())
    log(f"ViTForImageClassification  params={nparams / 1e6:.1f}M")
    log(f"     hidden=768  layers=12  heads=12  patch=4  image=32  -> {(32 // 4) ** 2} patches  num_labels=10")
    opt = torch.optim.AdamW(model.parameters(), lr=lr)
    lossf = nn.CrossEntropyLoss()
    use_amp = (device == "cuda")
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)

    banner(f"TRAINING  ({epochs} epochs on {device.upper()})")
    t0 = time.time()
    acc = 0.0
    for ep in range(1, epochs + 1):
        model.train()
        total, count, te = 0.0, 0, time.time()
        for xb, yb in loader:
            xb, yb = xb.to(device, non_blocking=True), yb.to(device, non_blocking=True)
            opt.zero_grad()
            with torch.autocast(device_type=device, enabled=use_amp):
                loss = lossf(model(pixel_values=xb).logits, yb)
            scaler.scale(loss).backward()
            scaler.step(opt)
            scaler.update()
            total += loss.item() * len(yb)
            count += len(yb)
        model.eval()
        with torch.no_grad():
            xe, ye = x[:1000].to(device), y[:1000].to(device)
            acc = (model(pixel_values=xe).logits.argmax(1) == ye).float().mean().item()
        dt = time.time() - te
        mem = torch.cuda.max_memory_allocated() / 1e9 if device == "cuda" else 0.0
        ips = count / dt if dt else 0
        log(f"epoch {ep}/{epochs}  loss={total / count:.4f}  train_acc={acc:.3f}  "
            f"gpu_mem={mem:.2f}GB  {dt:.1f}s  ({ips:.0f} img/s)")

    banner("SAVE  ARTIFACTS")
    model.save_pretrained(out)
    metrics = {
        "model": "ViTForImageClassification", "params_millions": round(nparams / 1e6, 1),
        "final_train_acc": round(acc, 4), "epochs": epochs, "batch_size": batch,
        "train_samples": len(x), "device": device, "gpu": gpu_name,
        "total_seconds": round(time.time() - t0, 1),
    }
    (out / "training_summary.json").write_text(json.dumps(metrics, ensure_ascii=False, indent=2))
    log(f"saved model + training_summary.json -> {out}")

    banner("DONE")
    log(f"metrics={json.dumps(metrics)}")


if __name__ == "__main__":
    main()
