# KETI AI Storage — 성능 테스트 보고서 (2026-06-17)

> 대상: 99 클러스터(cpu-master / csd-server-01 / gpu-server-03) · 빌드: 80 서버
> 목적: 시스템의 핵심 성능 주장(마이그레이션 시 CPU 50%/메모리 40% 절감, 정책
> 기반 자동 오케스트레이션)을 **정책 기반 자동 트리거**로 실측.

---

## 1. 요약 (TL;DR)

- ✅ **정책 기반 자동 트리거 체인은 완벽 작동.** 노드 부하 → forecaster CRITICAL
  판정 → policy-engine migration 정책 자동 생성(autoExecute) → orchestrator 실행.
- ✅ **마이그레이션 핵심 최적화(완료 컨테이너 제외) 작동.** 3컨테이너 중 완료된
  2개(completed-job, insight-trace)는 `should_migrate=false`로 제외, 실행 중 1개만 이동.
- 🔴 **그러나 마이그레이션이 실제로 완주하지 못함.** 버그 3개 발견. 2개는 수정·배포
  완료, 1개(구조적 데드락)는 수정 방향 확정·미적용.
- ❌ **CPU/메모리 절감 수치는 측정 불가** — 마이그레이션이 완주를 못 해
  optimized 리소스 미수집. **BUG-C 해결 후 재측정 필요.**

---

## 2. 자동 트리거 메커니즘 (입증됨)

```
gpu-server-03(64코어)에 CPU requests 55코어(86%) Pod 배치
  → forecaster: cpu_requests/capacity = 86% ≥ 85% → CRITICAL 판정
     (grpc_server.py:187 cpu_util=cpu_requests/capacity, multi_lightgbm.py:104 cpu_critical=0.85)
  → policy-engine: migration 정책 자동 생성, autoExecute=true → phase=Executing
     (우리가 고친 ISSUE-2 approve 덕분에 Executing까지 진행)
  → orchestrator: POST /api/v1/migrations 자동 호출, "1/1 containers will be migrated"
```
- **수동 API 호출이 아닌 시스템 자율 판단**임을 확인(사용자 요구사항).
- forecaster는 **실제 CPU 사용량이 아니라 `cpu_requests`**를 봄 → requests만 큰
  Pod으로도 CRITICAL 유발 가능(테스트 용이).

---

## 3. 발견된 버그 3개

### BUG-A: checkpoint PVC 이름 충돌 (수정·배포 완료 ✅)
- 위치: `ai-storage-orchestrator/pkg/controller/migration.go:335`
- 원인: `checkpoint-{podname}-{time.Now().Unix()}` — **초 단위 timestamp**.
  같은 Pod에 cpu/memory 마이그레이션이 같은 초에 실행 → 동일 PVC 이름 →
  `persistentvolumeclaims "..." already exists` 실패.
- 수정: PVC 이름에 `job.ID`(=`migration-<uuid8자>`) 포함 → 동시 실행도 유니크.
  (DNS-1123 길이 보호 포함)

### BUG-A': migrated Pod 이름 충돌 (수정·배포 완료 ✅)
- 위치: `ai-storage-orchestrator/pkg/k8s/client.go:296`
- 원인: BUG-A와 동일 패턴 — `{podname}-migrated-{Unix초}`. 동시 마이그레이션이
  같은 Pod 이름 → `pods "..." already exists` 실패.
- 수정: K8s `GenerateName` 사용(`{podname}-migrated-` prefix + K8s 자동 suffix).
  Create() 반환값에 실제 이름이 담겨 호출부 그대로 동작. → 라이브에서
  `...-migrated-tjkg7`(랜덤 suffix) 생성 확인.

### BUG-C: checkpoint PVC 데드락 (수정 방향 확정, 미적용 🔴 — 가장 치명적)
- 증상: migrated Pod이 `ContainerCreating`에서 영구 정지(100분+),
  checkpoint PVC는 `Pending`(WaitForFirstConsumer) 영구 유지.
- 근본 원인: **클러스터의 모든 SC(storage-l1/l2/l3/s3, high-throughput)가
  `WaitForFirstConsumer`**. checkpoint PVC는 SC="" → cluster default(storage-l2)
  → WaitForFirstConsumer.
  - PVC: "Pod이 써야 바인딩" (WaitForFirstConsumer) ↔
    Pod: "PVC가 바인딩돼야 시작"(checkpoint-volume 마운트) → **상호 대기 데드락**.
- 영향: **현재 클러스터에서 마이그레이션은 구조적으로 완주 불가능.**
  failed_migrations 누적(18+).
- 수정 방향(확정, 미적용):
  - provisioner `cluster.local/nfs-subdir-external-provisioner`는 **Immediate
    바인딩 지원**(NFS 동적 프로비저닝 즉시 가능).
  - ① **Immediate 바인딩 SC 신규 생성**(예: `checkpoint-immediate`,
    volumeBindingMode: Immediate) + ② orchestrator가 checkpoint PVC에 그 SC를
    명시하도록 설정화. 위치: `CreatePersistentVolumeClaim`(client.go:126)이
    SC를 빈값으로 넘김 → ConfigMap(`provisioning` 또는 신규 `migration` 섹션)에서
    `checkpoint_storage_class` 읽어 전달. `mc.checkpointSize`(migration.go:66)
    옆에 `checkpointStorageClass` 추가하는 패턴.

---

## 4. 부수 발견 (BUG-B, 환경 이슈)

### BUG-B: migration 정책 중복 무한 생성 (미수정, 별도 기록)
- 부하 지속 시 같은 워크로드에 migration 정책이 60초마다 누적(cpu/memory 각 다수).
  중복 방지(`policy_generator.go:226 policyKey=node-type-resource`, TTL 10분)는
  있으나 policy-engine 재시작 시 인메모리 `recentPolicies` 초기화로 리셋 가능.
- 수정 검토: 진행 중(Executing) 마이그레이션이 있는 워크로드엔 새 정책 생성 억제,
  또는 recentPolicies를 CR 조회 기반으로.

### 환경: 마이그레이션 대상이 Deployment 관리 Pod
- 테스트 중 forecaster가 `workflow-controller`(ReplicaSet/Deployment 관리 Pod)를
  마이그레이션 타깃팅. Deployment가 관리하는 Pod은 원본 삭제 시 즉시 재생성되어
  마이그레이션 의미가 약함. forecaster/generator가 **마이그레이션 적합 워크로드
  (Job/standalone Pod)만 타깃팅**하도록 개선 권고.

---

## 5. 성능 수치 (측정 결과)

| 지표 | 결과 | 비고 |
|---|---|---|
| 자동 트리거 체인 | ✅ 작동 | forecaster→policy-engine→orchestrator |
| 완료 컨테이너 제외 | ✅ 3개 중 2개 제외 | 핵심 최적화 확인 |
| 마이그레이션 완주 | ❌ 0건 성공 | BUG-C 데드락 |
| CPU 절감 % | 측정 불가 | optimized 리소스 미수집 |
| 메모리 절감 % | 측정 불가 | 동상 |

**결론**: 시스템의 마이그레이션 최적화 로직(완료 컨테이너 제외)은 정확하나,
**checkpoint PVC가 WaitForFirstConsumer SC와 충돌(BUG-C)해 마이그레이션이
완주를 못 하므로 절감 효과를 실측할 수 없다.** BUG-C 해결이 성능 측정의 선결 조건.

---

## 6. 다음 단계 (권고)

1. **(필수) BUG-C 수정**: Immediate 바인딩 SC 생성 + checkpoint PVC가 그 SC를
   쓰도록 설정화 → 마이그레이션 완주 가능하게.
2. **재측정**: BUG-C 수정 후 Job 타입 워크로드로 마이그레이션 유발 → CPU/메모리
   절감 % 실측.
3. **(선택) BUG-B**: 정책 중복 생성 억제.
4. **(선택) 타깃 선별**: Deployment 관리 Pod 마이그레이션 제외.

## 7. 적용된 수정 (배포 완료)
- `ai-storage-orchestrator`: BUG-A(checkpoint PVC 이름) + BUG-A'(migrated Pod 이름)
  → 이미지 재빌드 → 99 `ctr import` + rollout. 라이브 동작 확인.
- (GitOps 정석 반영: 이미지 `:latest` 동일하므로 platform YAML 변경 불필요.)
