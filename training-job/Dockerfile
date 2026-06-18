FROM python:3.11-slim
WORKDIR /app
# CUDA build of PyTorch (cu121) — matches the target node: RTX A6000 (Ampere, sm_86)
# with NVIDIA driver 535 / CUDA 12.2. The wheel bundles CUDA runtime libs; only the
# host driver is required at run time (cu121 needs driver >= 525, satisfied by 535).
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cu121
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY train.py .
ENTRYPOINT ["python", "-u", "train.py"]
