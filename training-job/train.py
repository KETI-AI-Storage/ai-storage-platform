"""ViT training — same model as the AI-Storage KFP pipeline's training stage, moved
into the GitOps image lane (commit -> CI build -> Docker Hub -> KFP/ArgoCD).

The model is UNCHANGED from the pipeline: HuggingFace ViTForImageClassification with
the exact same ViTConfig.  Only its location changed (inline string in kueue_job.py
-> this train.py baked into the training-job image).

I/O contract — works in BOTH lanes:
  • KFP pipeline step: env STORAGE_ROOT + INPUT_PATH + OUTPUT_PATH.  Reads the
    preprocessed pixel values produced by the upstream preprocessing stage and writes
    the trained model + summary under STORAGE_ROOT+OUTPUT_PATH (…/training).
  • Standalone GitOps Job: env OUTPUT_DIR (default /data), no INPUT_PATH -> falls back
    to a random sample so the Job is self-contained.
Env: EPOCHS (default 1).  GPU is used automatically when visible.
"""
import json
import os
from pathlib import Path

import numpy as np
import torch
from transformers import ViTConfig, ViTForImageClassification


def resolve_io():
    storage_root = os.getenv("STORAGE_ROOT", "")
    input_path = os.getenv("INPUT_PATH", "")
    output_path = os.getenv("OUTPUT_PATH", "")
    # output: KFP (STORAGE_ROOT+OUTPUT_PATH) preferred, else OUTPUT_DIR (gitops), else /data
    out = Path(storage_root + output_path) if (storage_root and output_path) \
        else Path(os.getenv("OUTPUT_DIR", "/data"))
    inp = Path(storage_root + input_path) if (storage_root and input_path) else None
    return inp, out


def load_pixels(inp, device):
    if inp is not None:
        f = inp / "vit_preprocessed_pixel_values.npy"
        if f.exists():
            print(f"[train] loading preprocessed input: {f}", flush=True)
            return torch.from_numpy(np.load(f)).float().to(device)
    print("[train] no preprocessed input -> random sample (self-contained)", flush=True)
    return torch.randn(1, 3, 32, 32, device=device)


def main():
    epochs = int(os.getenv("EPOCHS", "1"))
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"[train] torch={torch.__version__} cuda={torch.cuda.is_available()} device={device}", flush=True)
    if device == "cuda":
        p = torch.cuda.get_device_properties(0)
        print(f"[train] GPU={p.name} mem={p.total_memory/1e9:.0f}GB cc=sm_{p.major}{p.minor}", flush=True)

    inp, out = resolve_io()
    out.mkdir(parents=True, exist_ok=True)
    x = load_pixels(inp, device)

    # ── UNCHANGED model: exact same ViTConfig as the pipeline's inline stage ──
    config = ViTConfig(
        image_size=32, patch_size=16, hidden_size=64,
        num_hidden_layers=2, num_attention_heads=4,
        intermediate_size=128, num_labels=10,
    )
    model = ViTForImageClassification(config).to(device)
    model.train()
    opt = torch.optim.Adam(model.parameters(), lr=1e-3)
    y = torch.tensor([1] * x.shape[0], dtype=torch.long, device=device)

    last_loss = 0.0
    for ep in range(1, epochs + 1):
        opt.zero_grad()
        res = model(pixel_values=x, labels=y)
        res.loss.backward()
        opt.step()
        last_loss = float(res.loss.detach().cpu().item())
        print(f"[train] epoch {ep}/{epochs} loss={last_loss:.4f}", flush=True)

    model.save_pretrained(out)
    summary = out / "training_summary.json"
    summary.write_text(json.dumps(
        {"model": "ViTForImageClassification", "loss": last_loss, "epochs": epochs, "device": device},
        ensure_ascii=False, indent=2))
    print(f"[train] DONE model=ViTForImageClassification loss={last_loss:.4f} epochs={epochs} -> {out}", flush=True)


if __name__ == "__main__":
    main()
