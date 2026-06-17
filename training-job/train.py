"""Sample training job for the CI/CD reference pipeline.

Trains a tiny linear model with gradient descent on synthetic data and writes
metrics. Replace this with the real model code — the pipeline (build image ->
Docker Hub -> ArgoCD Job) stays the same.
"""
import json
import os
import random
import time


def main() -> None:
    epochs = int(os.getenv("EPOCHS", "20"))
    lr = float(os.getenv("LR", "0.1"))
    print(f"[train] start epochs={epochs} lr={lr}", flush=True)

    # synthetic data: y = 3x + 2 + noise
    random.seed(42)
    data = [(i / 10, 3 * (i / 10) + 2 + random.uniform(-0.5, 0.5)) for i in range(50)]
    n = len(data)

    w, b, loss = 0.0, 0.0, 0.0
    for epoch in range(1, epochs + 1):
        dw = db = 0.0
        for x, y in data:
            err = (w * x + b) - y
            dw += 2 * err * x
            db += 2 * err
        w -= lr * dw / n
        b -= lr * db / n
        loss = sum((w * x + b - y) ** 2 for x, y in data) / n
        print(f"[train] epoch {epoch:02d} loss={loss:.4f} w={w:.3f} b={b:.3f}", flush=True)
        time.sleep(0.2)

    metrics = {"final_loss": round(loss, 4), "w": round(w, 3), "b": round(b, 3), "epochs": epochs}
    print(f"[train] DONE metrics={json.dumps(metrics)}", flush=True)

    out_dir = os.getenv("OUTPUT_DIR", "/data")
    try:
        os.makedirs(out_dir, exist_ok=True)
        with open(os.path.join(out_dir, "metrics.json"), "w") as f:
            json.dump(metrics, f)
        print(f"[train] wrote {out_dir}/metrics.json", flush=True)
    except OSError as e:
        print(f"[train] no writable output dir ({e})", flush=True)


if __name__ == "__main__":
    main()
