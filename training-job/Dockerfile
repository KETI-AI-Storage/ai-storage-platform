FROM python:3.11-slim
WORKDIR /app
# CUDA build of PyTorch (cu128) — supports recent GPUs incl. Blackwell (sm_120).
# The wheel bundles CUDA runtime libs; only the host NVIDIA driver is required at run time.
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cu128
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY train.py .
ENTRYPOINT ["python", "-u", "train.py"]
