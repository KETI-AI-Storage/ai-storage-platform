# cifar10 pipeline image: one image, three baked scripts (preprocess/train/inference).
# Each Job runs a different script. Same torch base as training-job — already cached
# on the build-80 runner and proven on the A6000 (driver 535 / cu121).
FROM pytorch/pytorch:2.5.1-cuda12.1-cudnn9-runtime
WORKDIR /opt/workloads
COPY cifar10_preprocess.py cifar10_train.py cifar10_inference.py ./
