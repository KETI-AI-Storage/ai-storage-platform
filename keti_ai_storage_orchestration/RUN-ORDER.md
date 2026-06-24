# RUN-ORDER — 스크립트별 단계 실행 치트시트

데모/검증 때 **하나씩 따로 실행**(= 자연스러운 단계별 pause). 각 스크립트가 자기 헤더 + PASS/FAIL을 찍고 끝납니다.
한 번에 다 돌리려면 종합 스크립트 → `bash run-e2e.sh` (스테이지 사이 멈추려면 `--pause`).

- 실행 위치: **대상 클러스터**(로컬 kubectl). 노드명·KUBECONFIG 불필요(자동).
- GitOps 단계만 추가 전제: GitHub 토큰(`~/.git-credentials` 또는 `.env`). 모노레포는 `01-gitops-preflight.sh`가 `<패키지>/.monorepo`에 자동 clone.

---

## 0. 게이트 (읽기전용, ~10초) — 항상 먼저
```bash
bash demo-preflight.sh
```
**보는 것:** `✅ READY` + 자동탐지 TARGET_NODE. ❌면 `bash cleanup.sh` 후 재실행.

---

## 1. 설치 / 자격증명  *(이미 설치된 클러스터면 건너뜀)*
```bash
bash 00-install/01-install-components.sh        # 컴포넌트 설치 (CRD→stack→smoke)
bash 00-install/02-setup-credentials.sh         # (선택) 클러스터 Secret(imagePull/ArgoCD repo)
bash 00-install/03-setup-git-push.sh            # (GitOps용) git push 셋업: username+PAT → push 검증
```
**보는 것:** 설치 smoke PASS / `git push is READY`.

---

## 2. GitOps — 딜리버리 (코드→CI→레지스트리→ArgoCD)
```bash
bash 01-gitops/01-gitops-preflight.sh    # 게이트 (없으면 모노레포 자동 clone → <패키지>/.monorepo)
bash 01-gitops/02-run-gitops.sh cpu-eval # verify: 현재 배포가 GitOps로 맞는지 (읽기전용)
bash 01-gitops/03-update-workload.sh     # ① 워크로드 수정(현재시각) + 큐 hold + 스케줄링 hold 무장
bash 01-gitops/04-drive-demo.sh          # ② commit·push → CI빌드 → DockerHub → ArgoCD 배포 → 🛑 큐에서 대기
bash 01-gitops/05-queue-release.sh       # ③ 🛑 큐 → pause → release → admit → 파드가 🛑 스케줄링 직전 대기 (여기서 멈춤)
bash 02-scheduling/01-schedule-release.sh    # ④ 🛑 스케줄링 → 웹훅 주입 확인 → pause → release(노드 레이블) → 배치 → 실행
```
> **한 줄기 흐름 (같은 gitops 워크로드 하나가 처음부터 끝까지):**
> `03` 수정+큐/스케줄링 hold무장 → `04` 배포 → `05` 🛑큐→release→admit → `06` 🛑스케줄링→웹훅주입→release→배치→실행.
> 워크로드 위치 **`<패키지>/.monorepo/<workload>/`**. 반복: `cleanup.sh`(demo-admission-queue + demo-hold 라벨 정리).
> (빠르게: `03-update-workload.sh cpu-eval` 권장 — GPU·CI빌드 없이 ArgoCD sync만.)  GPU면 노드에 `nvidia.com/gpu=present` 라벨 필요(설치가 자동).
> 스케줄링 단계(🛑스케줄링 → 웹훅 주입 → 배치) 상세는 **§3** — 같은 워크로드가 이어집니다.
> (CI 빌드 포함 워크로드(training-job)는 04가 5–15분; build:false(cpu-eval)는 즉시 ArgoCD sync라 빠름.)
**보는 것:** verify `ALL CHECKS PASSED` / drive는 `code→CI→Docker Hub→ArgoCD→deployed @ <SHA>` + Actions 링크(🔗).
**범위:** 딜리버리(이미지 빌드→레지스트리→Synced/Healthy→롤아웃)까지만. webhook/스케줄링은 §3에서.  (~drive 5–15분)

---

## 3. 스케줄링 스톱 (02-scheduling) — gitops 한줄기의 마지막 단계
§2의 `05-queue-release`가 큐를 풀고 admit하면, `03`이 무장한 **스케줄링 hold(nodeSelector `keti.io/demo-hold`)** 때문에 파드가 **스케줄링 직전에 실제로 멈춰** 있습니다. 이 스크립트가 그 파드를 풀어 배치합니다. (§2와 **같은 gitops 워크로드** — 합성 트레이스 아님.)
```bash
bash 02-scheduling/01-schedule-release.sh   # 🛑 스케줄링 직전 대기 파드 → 웹훅 주입 확인 → pause → release(노드 레이블) → ai-storage-scheduler 배치 → 실행
```
**보는 것:** 웹훅이 `schedulerName=ai-storage-scheduler`·`insight-trace` 사이드카·`storage.keti.io/*` 주입(live) → 🛑 미배치 대기 → release(노드에 `keti.io/demo-hold` 라벨 + 파드 재생성) → 배치 → 실행 로그.
**정직 caveat:** ① 웹훅은 *파드 생성 시점*에 주입 — **`failurePolicy=Ignore`**라 웹훅 서버 죽으면 주입 없이 통과. ② **데모 전용 `demo-admission-queue` + `keti.io/demo-hold` 라벨만 토글**(공유 자원 안 건드림). ③ `ai-storage-scheduler`는 **schedulingGate 무시**라 스케줄링 hold는 nodeSelector로 구현 — release는 **노드에 라벨만 추가**하면 스케줄러가 대기 파드를 재평가해 배치함(**파드 삭제 안 함** — 삭제는 바인딩 레이스 + Job backoffLimit 소모로 치명적). ④ GPU 워크로드면 대상 노드에 `nvidia.com/gpu=present`도 필요(설치가 자동).

---

## 4. 오케스트레이션 — 6종 (타입별로 따로)
```bash
bash 03-orchestration/01-migration.sh      # ① 자율: 부하→CRITICAL→마이그→CPU49/Mem39 절감  (~6분)
bash 03-orchestration/02-scaling.sh        # ① 자율: STRESSED→autoscaler 활성화           (~6분)
bash 03-orchestration/03-provisioning.sh   # ② 직접: PVC 프로비저닝 액션                    (~30초)
bash 03-orchestration/04-preemption.sh     # ② 직접: 축출 액션 (0건, 무피해)               (~30초)
bash 03-orchestration/05-caching.sh        # ② 직접: 캐싱 액션 (active)                     (~30초)
bash 03-orchestration/06-loadbalancing.sh  # ② 직접: 밸런싱 액션 (0건, 무피해)             (~30초)
# 6종 묶음:  bash 03-orchestration/run-orchestration.sh   (PAUSE=1 로 타입 사이 멈춤)
```
**보는 것:** 각 `ALL CHECKS PASSED`.
**정직하게:** ①=자율 입증(migration·scaling, +provisioning 관찰) / ②=액션 실행 입증(GPU·스토리지 상황 합성불가라 ②).

---

## 5. 정리 (아무 때나)
```bash
bash cleanup.sh
```

---

## 한 번에 (종합 스크립트)

**시연용 (진짜 멈추는 한 줄기 — 같은 gitops 워크로드, 번호 순서대로, 플래그 없음):**
```bash
bash 01-gitops/03-update-workload.sh cpu-eval       # 워크로드 수정 + 큐/스케줄링 hold 무장
bash 01-gitops/04-drive-demo.sh                     # gitops: 수정한 워크로드 → CI → DockerHub → ArgoCD 배포
bash 01-gitops/05-queue-release.sh                  # 🛑 큐 → release → admit → 파드가 🛑 스케줄링 직전 대기
bash 02-scheduling/01-schedule-release.sh           # 🛑 스케줄링 → 웹훅 주입 확인 → release → 배치 → 실행
bash 03-orchestration/01-migration.sh               # 오케스트레이션(자율 트리거, 멈춤 없음)
```
> 흐름: **gitops 배포 → 🛑큐 → release → 🛑스케줄링 → 웹훅 → 배치 → 오케스트레이션(자율)** — 처음부터 끝까지 같은 워크로드.
> 각 🛑은 cosmetic이 아니라 **실제 K8s hold**(suspend된 Kueue Workload / nodeSelector 미배치 파드) — 다음 스크립트가 진짜 release.

**검증용 (스테이지 PASS/FAIL 집계):**
```bash
bash run-e2e.sh                 # preflight→orchestration(6)→cleanup  (스케줄링은 §2~§3 한줄기로 별도)
bash run-e2e.sh --install       # 설치부터
bash run-e2e.sh --gitops cpu-eval --pause   # gitops 포함 + 스테이지 사이 멈춤
```

> 빠른 살아있음 체크: **§0 게이트 → §4의 `04-preemption.sh`(30초)** 둘이면 패키지 생존 확인 끝.
> 자세한 기대출력/매트릭스/한계: **demo-runbook.md**.
