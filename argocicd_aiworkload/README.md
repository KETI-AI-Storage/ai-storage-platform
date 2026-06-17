# KETI AI Storage - Argo CD + Kubeflow Pipeline

KETI AI Storage 시스템의 Argo CD + Kubeflow 연동 테스트용 레포지토리입니다.

## 아키텍처

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          GitHub Repository                               │
│  ┌─────────────┐                    ┌─────────────┐                     │
│  │  workloads/ │                    │  pipelines/ │                     │
│  │ (단순 Pod)  │                    │(DAG 파이프라인)│                    │
│  └──────┬──────┘                    └──────┬──────┘                     │
└─────────┼──────────────────────────────────┼────────────────────────────┘
          │                                  │
          ▼                                  ▼
┌─────────────────┐              ┌─────────────────┐
│    Argo CD      │              │    Argo CD      │
│  (Application 1)│              │  (Application 2)│
└────────┬────────┘              └────────┬────────┘
         │                                │
         ▼                                ▼
┌─────────────────┐              ┌─────────────────────────┐
│ ai-workload-test│              │ kubeflow-user-example-com│
│   (Namespace)   │              │      (Namespace)        │
│                 │              │                         │
│ • bert-inference│              │  ┌─────────────────┐    │
│ • yolo-inference│              │  │ DAG Pipeline    │    │
│ • llama-training│              │  │                 │    │
│ • resnet-training│             │  │ preprocess      │    │
└────────┬────────┘              │  │     ↓           │    │
         │                       │  │ train (GPU)     │    │
         │                       │  │     ↓           │    │
         │                       │  │ evaluate        │    │
         │                       │  └────────┬────────┘    │
         │                       └───────────┼─────────────┘
         │                                   │
         └──────────────┬────────────────────┘
                        │ insight-trace (sidecar)
                        ▼
              ┌─────────────────┐
              │     APOLLO      │
              │ (Policy Server) │
              └─────────────────┘
```

## Kubeflow Pipeline (DAG)

### LLaMA Training Pipeline

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  preprocess  │───▶│    train     │───▶│   evaluate   │
│              │    │   (GPU)      │    │              │
│ - tokenize   │    │ - 3 epochs   │    │ - perplexity │
│ - batching   │    │ - checkpoint │    │ - BLEU score │
└──────────────┘    └──────────────┘    └──────────────┘
      2분                 5분                 2분
```

각 단계에 insight-trace 사이드카가 포함되어 APOLLO로 WorkloadSignature 전송.

## 단순 워크로드

### TEXT Workloads (NLP)
| 워크로드 | 타입 | 프레임워크 | 설명 |
|---------|------|-----------|------|
| `llama-training` | Job | PyTorch + HuggingFace | LLaMA 모델 학습 (GPU) |
| `bert-inference` | Deployment | PyTorch + HuggingFace | BERT 추론 서비스 |

### IMAGE Workloads (Computer Vision)
| 워크로드 | 타입 | 프레임워크 | 설명 |
|---------|------|-----------|------|
| `resnet-training` | Job | PyTorch + TorchVision | ResNet50 이미지 분류 학습 |
| `yolo-inference` | Deployment | PyTorch + Ultralytics | YOLOv8 객체 탐지 서비스 |

## 사용 방법

### 1. Argo CD Applications 등록
```bash
# 단순 워크로드 + Kubeflow Pipeline 모두 등록
kubectl apply -f argocd/

# 또는 개별 등록
kubectl apply -f argocd/application.yaml          # 단순 워크로드
kubectl apply -f argocd/pipeline-application.yaml # Kubeflow Pipeline
```

### 2. 동기화 상태 확인
```bash
kubectl get application -n argocd
```

### 3. Pipeline 실행 상태 확인
```bash
# Kubeflow Pipeline (Argo Workflow)
kubectl get workflows -n kubeflow-user-example-com

# 단순 워크로드
kubectl get pods -n ai-workload-test
```

### 4. 모니터링
```bash
# 단순 워크로드 모니터링
/root/workspace/integration-test/scripts/monitor-all.sh ai-workload-test

# Pipeline 모니터링
/root/workspace/integration-test/scripts/monitor-all.sh kubeflow-user-example-com
```

## 디렉토리 구조

```
argocicd_aiworload/
├── README.md
├── argocd/
│   ├── application.yaml          # 단순 워크로드 Application
│   ├── pipeline-application.yaml # Kubeflow Pipeline Application
│   └── kustomization.yaml
├── workloads/                    # 단순 Pod 워크로드
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── text/
│   │   ├── llama-training.yaml
│   │   └── bert-inference.yaml
│   └── image/
│       ├── resnet-training.yaml
│       └── yolo-inference.yaml
└── pipelines/                    # Kubeflow DAG 파이프라인
    ├── kustomization.yaml
    └── llama-training-pipeline.yaml
```

## 관련 프로젝트

- [insight-trace](https://github.com/KETI-AI-Storage/insight-trace): 런타임 워크로드 분석 사이드카
- [insight-scope](https://github.com/KETI-AI-Storage/insight-scope): 정적 YAML 분석
- [apollo](https://github.com/KETI-AI-Storage/apollo): 스토리지 정책 서버
