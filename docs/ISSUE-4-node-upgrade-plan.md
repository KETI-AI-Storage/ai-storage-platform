# ISSUE-4 — csd-server-01 노드 업그레이드 계획 (보류, 절차만 문서화)

> 상태: **보류**(2026-06-16 결정). 고위험 인프라 작업이라 ISSUE-1/2 코드 수정
> 이후 별도 일정에 진행. 이 문서는 실행 시 따라갈 단계별 절차.

## 현황 (99 클러스터, 진단 2026-06-16)

| 노드 | 역할 | kubelet | OS | containerd | 상태 |
|---|---|---|---|---|---|
| cpu-master-server | control-plane | v1.34.3 | Ubuntu 24.04 | 1.7.28 | 정상 |
| gpu-server-03 | worker | v1.32.9 | Ubuntu 22.04 | 2.1.5 | 허용범위(2단계) |
| **csd-server-01** | worker(CSD) | **v1.29.15** | **Ubuntu 18.04(EOL)** | 1.6.12 | 🔴 **skew 위반(5단계)** |

- kubeadm version-skew 정책: worker kubelet은 control-plane −3 이내여야 함
  → 1.34 기준 worker는 **1.31 이상**이어야 함. csd-server-01(1.29)은 위반.
- 근본 문제: **Ubuntu 18.04가 EOL** → kubelet만 올려도 OS 보안/패키지 한계 남음.

## 영향 평가 (낮음 — drain 안전)

- csd-server-01에 도는 워크로드: 데몬셋만(kube-flannel, node-exporter, insight-scope) + kube-proxy.
- **CSD 라벨(`csd.enabled`, `storage-tier/nvme`)을 강제하는 nodeSelector 배포 없음**
  → drain 시 Pending으로 막히는 워크로드 없음.
- 단, CSD 인식 스케줄링 테스트는 이 노드에 의존하므로 업그레이드 후 라벨 보존 필수.

## 권장안: OS 재설치 (EOL 때문에 단순 업그레이드보다 근본적)

### 옵션 A — kubelet 단계 업그레이드만 (OS 유지, 임시)
```bash
# 99 master에서 노드 drain
kubectl drain csd-server-01 --ignore-daemonsets --delete-emptydir-data
# csd-server-01에서 (SSH): 1.29 → 1.30 → 1.31 단계적 (한 마이너씩)
#   apt-mark unhold kubeadm && apt-get install -y kubeadm=1.30.x && kubeadm upgrade node
#   apt-get install -y kubelet=1.30.x kubectl=1.30.x && systemctl restart kubelet
#   → 검증 후 1.31.x 반복
kubectl uncordon csd-server-01
```
- 한계: Ubuntu 18.04 EOL은 그대로. containerd 1.6도 구버전.

### 옵션 B — OS 재설치 후 재조인 (권장, 근본)
1. `kubectl drain csd-server-01 --ignore-daemonsets --delete-emptydir-data`
2. `kubectl delete node csd-server-01`
3. csd-server-01에 Ubuntu 22.04+ 재설치, containerd 1.7+, kubeadm 1.31+ 설치
4. master에서 `kubeadm token create --print-join-command` → 노드에서 join
5. **CSD 라벨 복원**(중요):
   ```bash
   kubectl label node csd-server-01 csd.enabled=true storage-tier/nvme=true \
     storage-capability/csd-compute-ops=true storage-capability/write-buffer=true \
     ai-storage.keti.io/worker=true node-role.kubernetes.io/worker=
   ```
6. CSD 인식 스케줄링 검증: 테스트 Pod 투입 → csd-server-01 배치 확인.

## 검증 (업그레이드 후)
```bash
kubectl get nodes -o wide                       # csd-server-01 Ready + 버전 ≥1.31
kubectl get node csd-server-01 --show-labels     # CSD 라벨 보존 확인
# 스토리지 인식 스케줄링 회귀: injection-enabled ns에 Pod 투입 → 배치 정상 확인
```

## 선행 조건
- ISSUE-1/2 코드 수정·배포가 끝나 클러스터가 안정된 뒤 진행 권장.
- 업그레이드 중 csd-server-01 빠지면 스케줄 대상이 gpu-server-03+master로 축소됨.
