# ⚠️ 이 디렉토리는 ArgoCD 정본이 아닙니다 (DO NOT `kubectl apply`)

Kueue 큐/Flavor의 **실제 배포 정본(source of truth)** 은 99 GitOps 레포입니다:

```
ai-storage-gitops :: platform/generated/10-kueue-default-queues.yaml   (v1beta2, 3-flavor)
   ← ArgoCD app `ai-storage-platform` 이 git://10.0.4.99:9418/ai-storage-gitops.git 의
     platform/ 를 자동 sync (automated + selfHeal). 여기를 고치면 99에 자동 반영됨.
```

이 디렉토리(`kueue-config/`)의 YAML은 **참고/역사용** 입니다:
- API 버전이 `v1beta1`(deprecated) — 99 클러스터는 `v1beta2` 사용.
- LocalQueue 네임스페이스 등 라이브와 불일치 항목 있음.
- **ArgoCD가 읽지 않으므로** 여기를 고쳐도 클러스터에 반영되지 않습니다.

Kueue 큐 구성을 바꾸려면 위 GitOps 정본을 수정하세요. (selfHeal로 수동 변경은 곧 되돌아갑니다.)

설계 의도(3-flavor: default/csd/gpu 차등 큐잉)는 정본과 동일합니다.
