# AI Storage Webhook (Tier Mutation Stage)

현재 단계는 **Gluesys 4-tier 로지컬 검증 단계**입니다.

- 웹훅은 PVC 생성 시 `storageClassName`이 비어 있으면 워크로드 메타데이터를 기반으로 tier를 선택해 주입합니다.
- 선택 결과는 다음 PVC annotation/label로 기록됩니다.
  - `ai-storage/selected-tier`: 최종 tier 이름. 반드시 `L1` / `L2` / `L3` / `S3` 중 하나.
  - `ai-storage/selected-storage-class`: 매핑된 StorageClass 이름. `storage-l1` / `storage-l2` / `storage-l3` / `storage-s3` 중 하나.
  - `ai-storage/tier-reason`: 이번 admission에서 tier를 선택한 이유.
  - `storage.keti.io/tier-hint`: 정규화된 hint 값(L1~S3).
  - `ai-storage-selected-tier` label: 최종 tier 이름.

## Tier 정의 (Gluesys 기준)

| Tier | StorageClass   | tier-role        | dataClass  | 용도                                                   |
| ---- | -------------- | ---------------- | ---------- | ------------------------------------------------------ |
| L1   | `storage-l1`   | `cache-burst`    | `cache`    | 반복 접근, cache, metadata-cache, small I/O, ultra-low latency |
| L2   | `storage-l2`   | `nvme-hot`       | `hot`      | 전처리 입력, 학습 입력, 추론 입력, hot-data, low latency |
| L3   | `storage-l3`   | `hdd-capacity`   | `warm-cold`| 원본 대용량 데이터, 중간 산출물, warm/cold data           |
| S3   | `storage-s3`   | `object-archive` | `archive`  | 백업, 오래된 로그, 결과 장기보관                          |

## 기존 값(burst/cache/performance/capacity/archive) 호환

이번 단계에서 기존 burst/performance/capacity/archive 체계는 **호환 입력**으로만 인식되고,
최종 결과(annotation, label, StorageClass)에는 항상 L1/L2/L3/S3 표준 값만 기록됩니다.

| Legacy 입력          | Normalize 결과 |
| -------------------- | -------------- |
| `burst` / `cache`    | `L1`           |
| `performance`        | `L2`           |
| `capacity`           | `L3`           |
| `archive`            | `S3`           |
| `storage-burst`      | `storage-l1`   |
| `storage-performance`| `storage-l2`   |
| `storage-capacity`   | `storage-l3`   |
| `storage-archive`    | `storage-s3`   |

## 웹훅 동작 요약

1. PVC에 이미 명확한 `selected-tier` / `selected-storage-class` / `storageClassName` 이
   L1/L2/L3/S3 또는 그에 매핑되는 StorageClass 이름으로 박혀 있으면 그 값을 그대로
   사용합니다(덮어쓰지 않음).
2. 기존 값이 burst/performance/capacity/archive 같은 legacy 값이면 L1/L2/L3/S3 로
   정규화한 결과를 PVC에 다시 박습니다.
3. 위 단서가 없는 경우 PVC metadata 기반 scoring 으로 tier 를 결정합니다.
4. scoring 도 빈 값이면 안전망으로 `S3` 로 폴백합니다.

## 후속 단계

- Workload-type / data-role 기반 정밀한 tier 선정 정책 (priority / weight / AHP score)
- Gluesys CSI provisioner 연동 (현재는 NFS provisioner 로 검증)
- backend storage pool 정책 매핑
- node locality 기반 storage 선택 정책
