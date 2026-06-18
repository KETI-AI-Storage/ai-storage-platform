# Prebuilt PyTorch + CUDA runtime: torch 2.5.1 / CUDA 12.1 (cudnn9), same as the
# cu121 wheel we used to pip-install and matching the target node: RTX A6000
# (Ampere, sm_86) with NVIDIA driver 535 / CUDA 12.2 (cu121 needs driver >= 525).
# Using the prebuilt base drops the ~2.5GB torch install, so a cold build goes
# from minutes to seconds. The wheel bundles CUDA runtime libs; only the host
# driver is required at run time.
FROM pytorch/pytorch:2.5.1-cuda12.1-cudnn9-runtime
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY train.py .
ENTRYPOINT ["python", "-u", "train.py"]
