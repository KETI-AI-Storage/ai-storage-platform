# InStorage Preprocess Components

CSD 기반 컨테이너 오프로딩을 위한 3개 컴포넌트로 구성된 AI 전처리 시스템

## 구성 요소

### 1. instorage-preprocess-operator
- **위치**: 마스터 노드
- **역할**: PreprocessJob CRD 생성을 감지하고 전처리 작업을 스케줄링
- **기능**: 
  - PreprocessJob 리소스 관리
  - CSD 노드 선택 및 작업 배치
  - 작업 생명주기 관리

### 2. instorage-preprocess-manager  
- **위치**: 워커 노드
- **역할**: 해당 노드에 배치된 전처리 작업을 인식하여 CSD로 전달
- **기능**:
  - 노드별 작업 모니터링
  - CSD Preprocessor와 통신
  - 작업 상태 업데이트

### 3. instorage-preprocessor
- **위치**: CSD 내부
- **역할**: 실제 컨테이너 생성 및 관리
- **기능**:
  - Docker 컨테이너 생성/시작/관리
  - 볼륨 마운트 처리
  - 작업 실행 및 모니터링

## 프로젝트 구조

```
├── instorage-preprocess-operator/
│   ├── cmd/main.go
│   ├── pkg/
│   │   ├── apis/v1alpha1/types.go
│   │   └── controller/preprocessjob_controller.go
│   └── go.mod
├── instorage-preprocess-manager/
│   ├── cmd/main.go
│   ├── pkg/
│   │   └── manager/manager.go
│   └── go.mod
└── instorage-preprocessor/
    ├── cmd/main.go
    ├── pkg/
    │   ├── server/
    │   │   ├── server.go
    │   │   └── job_manager.go
    │   └── docker/client.go
    └── go.mod
```

## 빌드 및 실행

각 컴포넌트는 독립적인 Go 모듈로 구성되어 있습니다:

```bash
# Operator 빌드
cd instorage-preprocess-operator
go build -o bin/operator cmd/main.go

# Manager 빌드  
cd instorage-preprocess-manager
go build -o bin/manager cmd/main.go

# Preprocessor 빌드
cd instorage-preprocessor
go build -o bin/preprocessor cmd/main.go
```

## 주요 특징

- **Kubernetes Native**: controller-runtime 기반 operator 패턴
- **CSD 통합**: Docker API를 통한 컨테이너 관리
- **확장 가능**: 모듈식 아키텍처
- **모니터링**: 작업 상태 추적 및 로깅