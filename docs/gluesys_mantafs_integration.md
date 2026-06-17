# Gluesys MantaFS 통합 (1차 구현)

## 1. 통합 목적

KETI AI Storage Orchestrator와 Gluesys MantaFS 간 **Layer 2 스토리지 제어 통합**의 1차 구현입니다.

- **목표**: KETI가 워크로드 실행 정보와 데이터셋 사용 힌트를 MantaFS에 전달하는 구조를 만드는 것.
- **역할 분리**:
  - **KETI**: 워크로드/파드/데이터셋 관련 메타데이터만 전달. 스토리지 내부 캐시·티어·데이터 배치를 직접 제어하지 않음.
  - **Gluesys MantaFS**: 전달받은 정보를 바탕으로 **내부적으로** 캐시, 티어링, 데이터 배치 등을 판단·최적화.

즉, “KETI가 스토리지를 제어한다”가 아니라 “KETI가 정보를 넘기고, MantaFS가 스토리지 최적화를 수행한다”는 구조입니다.

---

## 2. KETI와 Gluesys 역할 분담

| 구분 | 역할 |
|------|------|
| **KETI** | `workload_id`, `namespace`, `pod_name`, `node_name`, `dataset_name`, `access_pattern`, `data_paths` 등의 정보를 MantaFS에 전달. 스토리지 내부 제어 로직은 구현하지 않음. |
| **Gluesys MantaFS** | 전달받은 정보를 바탕으로 내부적으로 캐시, 티어링, 데이터 배치 등을 판단·수행. |

- **KETI는 스토리지 내부 티어링/캐시/데이터 배치를 직접 제어하지 않습니다.**
- **KETI는 워크로드 실행 정보와 데이터셋 사용 힌트를 전달합니다.**
- **Gluesys MantaFS는 전달된 정보를 바탕으로 내부적으로 스토리지 최적화를 수행합니다.**

---

## 3. 1차 구현 범위 API 4개

이번 1차 구현에서는 아래 **4개 API/gRPC 인터페이스만** 반영합니다.

| API | 방향 | 목적 |
|-----|------|------|
| **PrepareDataset** | KETI → MantaFS | 워크로드 실행 정보 전달 |
| **ReleaseDatasetHint** | KETI → MantaFS | 데이터셋 사용 종료 알림 |
| **ReportPodPlacement** | KETI → MantaFS | Pod 스케줄링(배치) 결과 전달 |
| **ReportDatasetUsage** | KETI → MantaFS | 데이터셋 사용 정보 전달 |

---

## 4. 각 API별 전달 필드

### 4.1 PrepareDataset()

- **목적**: 워크로드 실행 정보 전달.
- **필드**:
  - `workload_id`: 워크로드 식별자
  - `namespace`: 네임스페이스
  - `pod_name`: Pod 이름
  - `dataset_name`: 데이터셋 식별자 (현재는 임시 휴리스틱으로 PVC 이름 사용. TODO: Insight/APOLLO 메타데이터로 교체)
  - `node_name`: 실행/예정 노드
  - `job_type`: 작업 유형 (예: migration, caching, provisioning)
  - `access_pattern`: 접근 패턴 (예: sequential_read, random_write)
  - `data_paths[]`: 데이터 경로 목록

### 4.2 ReleaseDatasetHint()

- **목적**: 데이터셋 사용 종료 알림.
- **필드**:
  - `workload_id`: 워크로드 식별자
  - `namespace`: 네임스페이스
  - `dataset_name`: 데이터셋 식별자
  - `reason`: 종료 사유

### 4.3 ReportPodPlacement()

- **목적**: Pod 스케줄링 결과 전달.
- **필드**:
  - `pod_name`: Pod 이름
  - `namespace`: 네임스페이스
  - `node_name`: 배치된 노드

### 4.4 ReportDatasetUsage()

- **목적**: 데이터셋 사용 정보 전달.
- **필드**:
  - `dataset_name`: 데이터셋 식별자
  - `workload_id`: 워크로드 식별자
  - `access_pattern`: 접근 패턴
  - `data_paths[]`: 데이터 경로 목록

---

## 5. 현재 구현 상태

- **형태**: **Stub / Skeleton**
  - `IntegrationClient` 인터페이스와 4개 메서드 시그니처가 정의되어 있으며, `MantaClient`가 이를 구현합니다.
  - 각 메서드는 **연결 여부 확인 → 로그 출력 → `NotImplemented` 또는 `BackendUnavailable` 반환**만 수행합니다.
- **실제 gRPC**: 아직 Gluesys 공식 proto/stub가 없으므로, **실제 MantaFS gRPC 호출은 연결되어 있지 않습니다.**
- **향후**: Gluesys에서 gRPC/proto 정의가 제공되면, `pkg/manta/client.go` 내 `TODO(gluesys)` 위치에 실제 RPC 호출을 연결하면 됩니다.

---

## 6. 제외된 범위 (이번 1차 구현에 포함되지 않음)

다음 기능은 **이번 1차 통합 범위에서 제외**되었습니다. 코드에서도 제거 또는 비활성화되어 있습니다.

- **WarmupCache**: 캐시 워밍 요청 (KETI가 캐시를 직접 워밍하는 구조 아님)
- **MigrateDataset**: 데이터셋 마이그레이션 요청 (스토리지 제어성 API)
- **GetNodeStorageLoad**: 노드별 스토리지 부하 조회
- **GetClusterStorageMetrics**: 클러스터 스토리지 메트릭 조회
- **GetDatasetLocations**: 데이터셋 위치 조회

위와 같은 “스토리지 제어·조회” 성격의 API는 1차 범위가 아니며, 필요 시 추후 단계에서 협의·추가할 수 있습니다.

---

## 7. 전체 호출 흐름 요약

1. **PrepareDataset**
   - **CachingController**: 캐시 생성 시(`CreateCache`) → 해당 데이터셋 사용 예정 힌트 전달.
   - **MigrationController**: 마이그레이션 시작 시(`executeMigration` 초반) → 타겟 노드로 데이터셋 사용 예정 힌트 전달.
   - **ProvisioningController**: PVC가 Bound 된 직후(`executeProvisioning` 성공 시) → 해당 PVC/데이터셋 사용 예정 힌트 전달.

2. **ReleaseDatasetHint**
   - **ProvisioningController**: 프로비저닝 삭제 시(`DeleteProvisioning`) → PVC 삭제 직전에 데이터셋 사용 종료 힌트 전달.

3. **ReportPodPlacement**
   - **MigrationController**: 최적화 Pod가 타겟 노드에서 Ready 된 직후(`createOptimizedPod` 내부, `WaitForPodReady` 성공 후) → Pod 이름·네임스페이스·배치 노드 전달.

4. **ReportDatasetUsage**
   - **CachingController**: 캐시 생성 시(`CreateCache`) → PrepareDataset 직후, 해당 캐시 작업이 데이터셋을 사용한다는 정보 전달.

모든 MantaFS 호출은 **best-effort**이며, 실패 시 로그만 남기고 기존 Kubernetes 기반 동작은 그대로 유지됩니다. HTTP API 및 컨트롤러 상태 머신·응답 스키마는 변경되지 않습니다.

---

## 8. 코드 위치 참고

| 항목 | 경로 |
|------|------|
| 인터페이스·요청/응답 타입 | `ai-storage-orchestrator/pkg/manta/integration.go` |
| MantaClient 구현 (stub) | `ai-storage-orchestrator/pkg/manta/client.go` |
| CachingController 연동 | `ai-storage-orchestrator/pkg/controller/caching.go` |
| MigrationController 연동 | `ai-storage-orchestrator/pkg/controller/migration.go` |
| ProvisioningController 연동 | `ai-storage-orchestrator/pkg/controller/provisioning.go` |
| 의존성 주입 | `ai-storage-orchestrator/cmd/main.go` |

LoadbalancingController에는 `mantaClient` 필드만 유지하고, GetNodeStorageLoad 등 스토리지 부하 조회 호출은 제거된 상태입니다.
