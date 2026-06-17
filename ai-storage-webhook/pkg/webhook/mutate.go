// =============================================================================
// AI Storage Mutating Webhook - Core Mutation Logic
//
// 이 파일이 웹훅의 핵심 로직.
// Kubernetes API Server로부터 AdmissionReview 요청을 받아서
// Pod spec에 JSON Patch를 생성하여 반환.
//
// 주입 항목 3가지:
//  1. spec.schedulerName = "ai-storage-scheduler"
//  2. spec.shareProcessNamespace = true
//  3. spec.containers에 insight-trace 사이드카 추가
//
// 주입 조건:
//   - 네임스페이스에 label "keti-ai-storage-injection=enabled" 가 있을 때만
//   - Pod에 이미 insight-trace 컨테이너가 있으면 중복 주입 안함
//   - Pod에 label "keti-ai-storage-injection=disabled" 가 있으면 제외
//
// =============================================================================
package webhook

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"net/url"
	"strconv"
	"strings"
	"time"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// =============================================================================
// WebhookConfig: 웹훅 동작에 필요한 설정값
//
// main.go에서 플래그/환경변수로 받아서 전달.
// 이 값들이 실제 Pod에 주입되는 내용을 결정함.
// =============================================================================
type WebhookConfig struct {
	SidecarImage   string // Insight-Trace 컨테이너 이미지 (예: ketidevit2/insight-trace:latest)
	ApolloEndpoint string // APOLLO gRPC 주소 (사이드카 env로 주입)
	SchedulerName  string // 강제 적용할 스케줄러 이름 (예: ai-storage-scheduler)
	PlanAPIBaseURL string // 오케스트레이터 StageExecutionPlan 조회 API 베이스 URL
	// ReplaceableStorageClasses: API 서버 DefaultStorageClass 등으로 먼저 채워진 SC 이름 목록.
	// 이 목록에 포함되면 "사용자가 명시한 SC"로 보지 않고 티어 정책 SC로 교체한다.
	ReplaceableStorageClasses []string
}

// =============================================================================
// MutationHandler: HTTP 요청을 처리하는 핸들러
//
// K8s API Server가 POST /mutate 로 요청을 보내면
// Handle() 메서드가 호출됨.
// =============================================================================
type MutationHandler struct {
	config WebhookConfig
	// kubeClient is optional. Unit tests may not have in-cluster config,
	// so if client initialization fails we simply skip PVC lookups for pod logs.
	kubeClient kubernetes.Interface
	httpClient *http.Client
}

func NewMutationHandler(config WebhookConfig) *MutationHandler {
	h := &MutationHandler{
		config: config,
		httpClient: &http.Client{
			Timeout: 3 * time.Second,
		},
	}

	restCfg, err := rest.InClusterConfig()
	if err == nil && restCfg != nil {
		if client, cErr := kubernetes.NewForConfig(restCfg); cErr == nil {
			h.kubeClient = client
		} else {
			log.Printf("[Webhook] kubeClient init failed: %v", cErr)
		}
	}

	return h
}

// ReplaceableStorageClassesFromEnv는 AI_STORAGE_REPLACEABLE_STORAGE_CLASSES를 파싱한다.
// 미설정 시 기본값 ["nfs-client"] (클러스터 DefaultStorageClass가 웹훅보다 먼저 붙는 경우 대비).
// "none"이면 교체하지 않음(기존 SC가 있으면 항상 유지).
func ReplaceableStorageClassesFromEnv() []string {
	v := strings.TrimSpace(os.Getenv("AI_STORAGE_REPLACEABLE_STORAGE_CLASSES"))
	if v == "" {
		return []string{"nfs-client"}
	}
	if strings.EqualFold(v, "none") {
		return nil
	}
	var out []string
	for _, p := range strings.Split(v, ",") {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// =============================================================================
// patchOperation: JSON Patch (RFC 6902) 단일 연산
//
// Kubernetes 뮤테이팅 웹훅은 JSON Patch 형식으로 변경사항을 전달.
// 예시:
//
//	{"op": "replace", "path": "/spec/schedulerName", "value": "ai-storage-scheduler"}
//
// Op 종류:
//
//	"add"     - 필드가 없으면 추가
//	"replace" - 기존 필드 값 교체
//	"remove"  - 필드 삭제
//
// Path: JSON Pointer 형식 (RFC 6901)
//
//	/spec/schedulerName          → pod.spec.schedulerName
//	/spec/containers/-           → containers 배열 끝에 추가
//	/spec/shareProcessNamespace  → pod.spec.shareProcessNamespace
//
// =============================================================================
type patchOperation struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

type stageExecutionPlan struct {
	RunID              string                 `json:"run_id"`
	TargetStage        string                 `json:"target_stage"`
	Kind               string                 `json:"kind"`
	ResourceRequests   map[string]string      `json:"resource_requests,omitempty"`
	SchedulerName      string                 `json:"scheduler_name,omitempty"`
	NodeSelector       map[string]string      `json:"node_selector,omitempty"`
	Affinity           map[string]interface{} `json:"affinity,omitempty"`
	QueueLabel         string                 `json:"queue_label,omitempty"`
	StorageAnnotations map[string]string      `json:"storage_annotations,omitempty"`
	PolicyAnnotations  map[string]string      `json:"policy_annotations,omitempty"`
}

const (
	storageTierAnnotation  = "storage-tier"
	selectedTierAnnotation = "ai-storage/selected-tier"
	selectedTierLabel      = "ai-storage-selected-tier"

	// Gluesys 기준 표준 4-tier StorageClass 이름.
	// 기존 burst/performance/capacity/archive 는 호환 입력으로만 허용하고
	// 최종 결과는 storage-l1/l2/l3/s3 만 사용한다.
	storageClassL1 = "storage-l1"
	storageClassL2 = "storage-l2"
	storageClassL3 = "storage-l3"
	storageClassS3 = "storage-s3"

	// 표준 tier 라벨 값. PVC/Pod annotation/label 의 selected-tier 와 동일 기준이다.
	tierL1 = "L1"
	tierL2 = "L2"
	tierL3 = "L3"
	tierS3 = "S3"

	workloadTypeLabel  = "workload.keti.io/type"
	workloadStageLabel = "workload.keti.io/stage"

	tierHintAnnotation             = "storage.keti.io/tier-hint"
	selectedStorageClassAnnotation = "ai-storage/selected-storage-class"
	tierReasonAnnotation           = "ai-storage/tier-reason"
	datasetSizeAnnotation          = "storage.keti.io/dataset-size"
	checkpointAnnotation           = "storage.keti.io/checkpoint"
	prefetchAnnotation             = "storage.keti.io/prefetch"
	latencyAnnotation              = "storage.keti.io/latency"
	archivePolicyAnnotation        = "storage.keti.io/archive-policy"

	// 2단계 rule 기반 tier 선정용 PVC annotation 키.
	// scoring 진입 전 storage.keti.io/{workload-type,data-role,priority}와
	// storage.keti.io/tier-hint 값으로 우선 결정한다.
	workloadTypeHintAnnotation = "storage.keti.io/workload-type"
	dataRoleAnnotation         = "storage.keti.io/data-role"
	priorityAnnotation         = "storage.keti.io/priority"

	// 3단계 Hard Rule + AHP Score Rule 입력용 PVC annotation 키.
	// AHP 가중치 score 합산 및 hard rule 조건 평가에 사용된다.
	weightAnnotation        = "storage.keti.io/weight"
	ioPatternAnnotation     = "storage.keti.io/io-pattern"
	accessPatternAnnotation = "storage.keti.io/access-pattern"

	// DatasetInfo 대응 메타데이터(현재는 선정에 사용하지 않고 보존/패스스루 목적).
	projectIDAnnotation   = "storage.keti.io/project-id"
	datasetNameAnnotation = "storage.keti.io/dataset-name"

	checkpointPathKey1 = "checkpointPath"
	checkpointPathKey2 = "storage.keti.io/checkpointPath"

	defaultDatasetSize   = "0"
	defaultPrefetch      = "false"
	defaultLatencyMs     = "0ms"
	defaultArchivePolicy = "default"

	metadataStageLabel          = "stage"
	metadataStageAnnotation     = "ai-storage/stage"
	metadataGPUCountLabel       = "gpuCount"
	metadataGPUCountLabelAlt    = "gpu-count"
	metadataGPUCountAnnotation  = "ai-storage/gpu-count"
	metadataFrameworkLabel      = "framework"
	metadataFrameworkAnnotation = "ai-storage/framework"
	workloadFrameworkLabel      = "workload.keti.io/framework"
	workloadTypeAnnotation      = "workload.keti.io/type"
	workloadKindLabel           = "workload.keti.io/kind"
	mountPathLabel              = "workload.keti.io/mount-path"
	readOnlyLabel               = "workload.keti.io/read-only"
	pvcCountLabel               = "workload.keti.io/pvc-count"
	replicaCountLabel           = "workload.keti.io/replica-count"
)

// admissionResourceKind는 AdmissionReview 요청의 대상 리소스 종류를 반환한다.
// 일부 API Server/버전에서 request.Kind.Kind가 비어 있을 수 있으므로
// request.Resource.Resource로 폴백한다.
func admissionResourceKind(req *admissionv1.AdmissionRequest) string {
	if req == nil {
		return ""
	}
	if req.Kind.Kind != "" {
		return req.Kind.Kind
	}
	switch req.Resource.Resource {
	case "pods":
		return "Pod"
	case "persistentvolumeclaims":
		return "PersistentVolumeClaim"
	default:
		return ""
	}
}

// =============================================================================
// Handle: 웹훅 메인 핸들러
//
// 전체 흐름:
//  1. HTTP Body에서 AdmissionReview 읽기
//  2. AdmissionReview.Request에서 Pod 추출
//  3. createPatch()로 JSON Patch 생성
//  4. AdmissionReview.Response에 패치 담아서 응답
//
// AdmissionReview 구조:
//
//	{
//	  "apiVersion": "admission.k8s.io/v1",
//	  "kind": "AdmissionReview",
//	  "request": {
//	    "uid": "고유ID",
//	    "object": { ... Pod JSON ... },
//	    "namespace": "kubeflow-user-example-com"
//	  }
//	}
//
// =============================================================================
func (h *MutationHandler) Handle(w http.ResponseWriter, r *http.Request) {
	// =========================================================================
	// Step 1: HTTP Body 읽기
	// K8s API Server가 보내는 AdmissionReview JSON을 읽음
	// =========================================================================
	body, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("[Webhook] Failed to read request body: %v", err)
		http.Error(w, "Failed to read body", http.StatusBadRequest)
		return
	}

	// =========================================================================
	// Step 2: AdmissionReview 디시리얼라이즈
	// JSON → Go 구조체 변환
	// =========================================================================
	var admissionReview admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &admissionReview); err != nil {
		log.Printf("[Webhook] Failed to unmarshal AdmissionReview: %v", err)
		http.Error(w, "Failed to unmarshal", http.StatusBadRequest)
		return
	}

	request := admissionReview.Request
	if request == nil {
		log.Printf("[Webhook] Empty admission request")
		http.Error(w, "Empty request", http.StatusBadRequest)
		return
	}

	log.Printf("[Webhook] Processing: namespace=%s, name=%s, uid=%s",
		request.Namespace, request.Name, request.UID)

	// =========================================================================
	// Step 3: 리소스 Kind별 패치 생성
	//   - Pod: 기존 scheduler/sidecar 주입
	//   - PVC: storageClassName 티어 기반 자동 주입
	// =========================================================================
	var (
		patches []patchOperation
		message string
	)

	// AdmissionRequest.Kind는 환경에 따라 비어 있을 수 있으므로 Resource로 폴백한다.
	switch admissionResourceKind(request) {
	case "Pod":
		var pod corev1.Pod
		if err := json.Unmarshal(request.Object.Raw, &pod); err != nil {
			log.Printf("[Webhook] Failed to unmarshal Pod: %v", err)
			h.sendResponse(w, request.UID, false, "Failed to unmarshal pod", nil)
			return
		}

		if pod.Labels != nil && pod.Labels["keti-ai-storage-injection"] == "disabled" {
			log.Printf("[Webhook] Pod %s has injection disabled, skipping", pod.Name)
			h.sendResponse(w, request.UID, true, "Injection disabled by label", nil)
			return
		}

		patches = h.createPatch(&pod)
		message = "Pod mutated"

	case "PersistentVolumeClaim":
		var pvc corev1.PersistentVolumeClaim
		if err := json.Unmarshal(request.Object.Raw, &pvc); err != nil {
			log.Printf("[Webhook] Failed to unmarshal PVC: %v", err)
			h.sendResponse(w, request.UID, false, "Failed to unmarshal pvc", nil)
			return
		}

		patches = h.createPVCPatch(&pvc)
		message = "PVC mutated"

	default:
		log.Printf("[Webhook] Unsupported kind=%s (resource=%s), skipping mutation",
			request.Kind.Kind, request.Resource.Resource)
		h.sendResponse(w, request.UID, true, "Unsupported kind", nil)
		return
	}

	if len(patches) == 0 {
		log.Printf("[Webhook] No patches needed for kind=%s name=%s", admissionResourceKind(request), request.Name)
		h.sendResponse(w, request.UID, true, "No changes needed", nil)
		return
	}

	// =========================================================================
	// Step 6: 패치를 JSON으로 직렬화하여 응답
	// =========================================================================
	patchBytes, err := json.Marshal(patches)
	if err != nil {
		log.Printf("[Webhook] Failed to marshal patches: %v", err)
		h.sendResponse(w, request.UID, false, "Failed to marshal patches", nil)
		return
	}

	log.Printf("[Webhook] Applying %d patches to %s %s/%s",
		len(patches), admissionResourceKind(request), request.Namespace, request.Name)

	h.sendResponse(w, request.UID, true, message, patchBytes)
}

// =============================================================================
// createPatch: 실제 패치 내용을 생성하는 핵심 함수
//
// Pod의 현재 상태를 보고, 필요한 변경사항(패치)을 결정.
//
// 패치 3가지:
//  1. schedulerName 변경/추가
//  2. shareProcessNamespace = true 설정
//  3. insight-trace 사이드카 컨테이너 추가
//
// 각 패치는 독립적으로 적용 여부를 판단:
//   - 이미 올바른 값이면 스킵
//   - 이미 사이드카가 있으면 스킵
//
// =============================================================================
func (h *MutationHandler) createPatch(pod *corev1.Pod) []patchOperation {
	var patches []patchOperation

	plan := h.lookupStageExecutionPlanFromMetadata(pod.Labels, pod.Annotations)

	// =========================================================================
	// Patch 1: schedulerName 강제 설정
	//
	// 사용자가 어떤 스케줄러를 지정했든 (혹은 안 했든)
	// ai-storage-scheduler로 변경.
	//
	// pod.Spec.SchedulerName이:
	//   "" (빈 문자열) → K8s가 default-scheduler 사용
	//   "default-scheduler" → 기본 스케줄러
	//   "ai-storage-scheduler" → 이미 올바름 (스킵)
	//   기타 → 우리 스케줄러로 교체
	//
	// JSON Patch "replace" 사용:
	//   schedulerName 필드는 항상 존재 (빈 문자열이라도)
	//   하므로 "add"가 아닌 "replace" 사용
	// =========================================================================
	wantScheduler := h.config.SchedulerName
	if plan != nil && strings.TrimSpace(plan.SchedulerName) != "" {
		wantScheduler = strings.TrimSpace(plan.SchedulerName)
	}
	if pod.Spec.SchedulerName != wantScheduler {
		patches = append(patches, patchOperation{
			Op:    "replace",
			Path:  "/spec/schedulerName",
			Value: wantScheduler,
		})
		log.Printf("[Webhook]   → schedulerName: %q → %q",
			pod.Spec.SchedulerName, wantScheduler)
	}

	// =========================================================================
	// Patch 2: shareProcessNamespace = true
	//
	// Insight-Trace 사이드카가 메인 컨테이너의 프로세스를 모니터링하려면
	// 같은 PID 네임스페이스를 공유해야 함.
	//
	// pod.Spec.ShareProcessNamespace는 *bool 타입 (포인터):
	//   nil   → 설정 안 됨 (기본값 false) → "add"로 추가
	//   false → 명시적 비활성화 → "replace"로 변경
	//   true  → 이미 올바름 → 스킵
	//
	// 포인터인 이유: K8s가 "설정 안 함"과 "false"를 구분하기 위해
	// =========================================================================
	shareProcessNamespace := true
	if pod.Spec.ShareProcessNamespace == nil {
		// 필드 자체가 없으면 "add"
		patches = append(patches, patchOperation{
			Op:    "add",
			Path:  "/spec/shareProcessNamespace",
			Value: shareProcessNamespace,
		})
		log.Printf("[Webhook]   → shareProcessNamespace: nil → true")
	} else if !*pod.Spec.ShareProcessNamespace {
		// false로 설정되어 있으면 "replace"
		patches = append(patches, patchOperation{
			Op:    "replace",
			Path:  "/spec/shareProcessNamespace",
			Value: shareProcessNamespace,
		})
		log.Printf("[Webhook]   → shareProcessNamespace: false → true")
	}

	// =========================================================================
	// Patch 3: Insight-Trace 사이드카 컨테이너 주입
	//
	// 먼저 기존 컨테이너 중에 "insight-trace"라는 이름이 있는지 확인.
	// 있으면 중복 주입 방지를 위해 스킵.
	//
	// 사이드카 주입 시 "add" + path "/spec/containers/-" 사용:
	//   "-"는 JSON Pointer에서 "배열의 끝"을 의미
	//   즉, containers 배열의 마지막에 추가
	// =========================================================================
	if !h.hasSidecar(pod) {
		sidecar := h.buildSidecarContainer(pod)
		patches = append(patches, patchOperation{
			Op:    "add",
			Path:  "/spec/containers/-",
			Value: sidecar,
		})
		log.Printf("[Webhook]   → insight-trace sidecar injected (image: %s)", h.config.SidecarImage)
	} else {
		log.Printf("[Webhook]   → insight-trace sidecar already exists, skipping")
	}

	// Pod에도 KETI 표준 메타데이터를 주입/보정한다.
	// 참조 PVC의 라벨/어노테이션을 Pod 메타에 병합한 뷰로 tier를 계산하면(스코어링과 동일 입력),
	// PVC에만 framework/mount-path/kind 등이 있어도 Pod 티어가 맞게 나온다.
	effLabels, effAnn := h.podMetadataEffectiveForTier(pod)
	tier := selectTierFromMetadataMaps(effLabels, effAnn)
	patches = append(patches, buildKetiMetadataPatches(pod.Labels, pod.Annotations, tier)...)
	patches = append(patches, metadataFillPatches(pod, effLabels, effAnn)...)
	patches = append(patches, h.buildPodStageExecutionPlanPatches(pod, plan)...)

	// In order to debug "webhook added pod fields + pvc storage tier",
	// we also fetch referenced PVCs and print SC/tier under pod mutation logs.
	h.logPodReferencedPVCs(pod)

	return patches
}

func (h *MutationHandler) logPodReferencedPVCs(pod *corev1.Pod) {
	if pod == nil {
		return
	}
	if h.kubeClient == nil {
		return
	}

	// Collect PVCs referenced by this Pod.
	pvcNames := make([]string, 0)
	for _, v := range pod.Spec.Volumes {
		if v.PersistentVolumeClaim == nil {
			continue
		}
		if cn := strings.TrimSpace(v.PersistentVolumeClaim.ClaimName); cn != "" {
			pvcNames = append(pvcNames, cn)
		}
	}
	if len(pvcNames) == 0 {
		return
	}

	entries := make([]string, 0, len(pvcNames))
	for _, pvcName := range pvcNames {
		pvc, err := h.kubeClient.CoreV1().PersistentVolumeClaims(pod.Namespace).Get(
			context.Background(), pvcName, metav1.GetOptions{},
		)
		if err != nil {
			entries = append(entries, fmt.Sprintf("%s(sc=<lookup-failed:%v>)", pvcName, err))
			continue
		}

		storageClass := "<empty>"
		if pvc.Spec.StorageClassName != nil && strings.TrimSpace(*pvc.Spec.StorageClassName) != "" {
			storageClass = strings.TrimSpace(*pvc.Spec.StorageClassName)
		}

		selectedTierA := pvc.Annotations[selectedTierAnnotation]
		selectedTierL := pvc.Labels[selectedTierLabel]
		stage := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, metadataStageLabel, metadataStageAnnotation, workloadStageLabel)
		gpuCount := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, metadataGPUCountLabel, metadataGPUCountLabelAlt, metadataGPUCountAnnotation)

		fw := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, workloadFrameworkLabel, metadataFrameworkLabel, metadataFrameworkAnnotation)
		mp := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, mountPathLabel)
		wk := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, workloadKindLabel)
		pvcN := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, pvcCountLabel)
		repl := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, replicaCountLabel)

		entries = append(entries, fmt.Sprintf("%s(sc=%s,tier=%s/%s,stage=%s,gpuCount=%s,fw=%s,mount=%s,kind=%s,pvcCount=%s,replica=%s)",
			pvcName, storageClass, selectedTierA, selectedTierL, stage, gpuCount, fw, mp, wk, pvcN, repl))
	}

	log.Printf("[Webhook][PodPVC] %s/%s PVCs: %s",
		pod.Namespace, pod.Name, strings.Join(entries, ", "))
}

// podMetadataEffectiveForTier merges referenced PVC labels/annotations into a view of Pod metadata
// (only fills keys that are empty on the Pod) so tier selection matches StorageClass scoring inputs.
// Also sets workload.keti.io/kind from OwnerReferences (e.g. Job → job) when missing.
func (h *MutationHandler) podMetadataEffectiveForTier(pod *corev1.Pod) (map[string]string, map[string]string) {
	labels := make(map[string]string)
	if pod.Labels != nil {
		for k, v := range pod.Labels {
			labels[k] = v
		}
	}
	annotations := make(map[string]string)
	if pod.Annotations != nil {
		for k, v := range pod.Annotations {
			annotations[k] = v
		}
	}
	if h.kubeClient != nil {
		for _, vol := range pod.Spec.Volumes {
			if vol.PersistentVolumeClaim == nil {
				continue
			}
			cn := strings.TrimSpace(vol.PersistentVolumeClaim.ClaimName)
			if cn == "" {
				continue
			}
			pvc, err := h.kubeClient.CoreV1().PersistentVolumeClaims(pod.Namespace).Get(
				context.Background(), cn, metav1.GetOptions{})
			if err != nil {
				continue
			}
			mergePVCIntoPodMetadata(&labels, &annotations, pvc)
		}
	}
	if v := inferWorkloadKindFromOwner(pod); v != "" && strings.TrimSpace(labels[workloadKindLabel]) == "" {
		labels[workloadKindLabel] = v
	}
	return labels, annotations
}

func mergePVCIntoPodMetadata(labels, annotations *map[string]string, pvc *corev1.PersistentVolumeClaim) {
	if pvc.Labels != nil {
		for k, v := range pvc.Labels {
			if strings.TrimSpace(v) == "" {
				continue
			}
			if strings.TrimSpace((*labels)[k]) == "" {
				(*labels)[k] = v
			}
		}
	}
	if pvc.Annotations != nil {
		for k, v := range pvc.Annotations {
			if strings.TrimSpace(v) == "" {
				continue
			}
			if strings.TrimSpace((*annotations)[k]) == "" {
				(*annotations)[k] = v
			}
		}
	}
}

func inferWorkloadKindFromOwner(pod *corev1.Pod) string {
	for _, ref := range pod.OwnerReferences {
		if ref.Controller == nil || !*ref.Controller {
			continue
		}
		switch strings.ToLower(ref.Kind) {
		case "job":
			return "job"
		case "statefulset":
			return "statefulset"
		case "deployment":
			return "deployment"
		default:
			return ""
		}
	}
	return ""
}

// metadataFillPatches adds label/annotation keys from the effective merged view when the Pod has them empty.
func metadataFillPatches(pod *corev1.Pod, effLabels, effAnnotations map[string]string) []patchOperation {
	var patches []patchOperation
	origL := pod.Labels
	if origL == nil {
		origL = map[string]string{}
	}
	origA := pod.Annotations
	if origA == nil {
		origA = map[string]string{}
	}

	labelAdds := make(map[string]string)
	for k, want := range effLabels {
		if strings.TrimSpace(want) == "" {
			continue
		}
		if strings.TrimSpace(origL[k]) != "" {
			continue
		}
		labelAdds[k] = want
	}
	if len(labelAdds) > 0 {
		if pod.Labels == nil {
			patches = append(patches, patchOperation{Op: "add", Path: "/metadata/labels", Value: labelAdds})
		} else {
			for k, v := range labelAdds {
				patches = append(patches, patchOperation{
					Op:    "add",
					Path:  "/metadata/labels/" + jsonPointerEscape(k),
					Value: v,
				})
			}
		}
	}

	annAdds := make(map[string]string)
	for k, want := range effAnnotations {
		if strings.TrimSpace(want) == "" {
			continue
		}
		if strings.TrimSpace(origA[k]) != "" {
			continue
		}
		annAdds[k] = want
	}
	if len(annAdds) > 0 {
		if pod.Annotations == nil {
			patches = append(patches, patchOperation{Op: "add", Path: "/metadata/annotations", Value: annAdds})
		} else {
			for k, v := range annAdds {
				patches = append(patches, patchOperation{
					Op:    "add",
					Path:  "/metadata/annotations/" + jsonPointerEscape(k),
					Value: v,
				})
			}
		}
	}
	return patches
}

func (h *MutationHandler) createPVCPatch(pvc *corev1.PersistentVolumeClaim) []patchOperation {
	// 요청사항: StorageClass 선택은 Pod 역조회 없이 PVC metadata만 기반으로 판단한다.
	//
	// 결정 우선순위(Gluesys L1/L2/L3/S3, 3단계 Hard Rule + AHP Score Rule):
	//   1) existingFinalTierFromPVC — PVC 에 이미 표준 selected-tier /
	//      selected-storage-class / storageClassName 이 박혀 있으면 보존(legacy normalize).
	//   2) hardRuleSelect — tier-hint / archive-계열 data-role / cache+repeated|ultra-low
	//      조건. 매칭되면 score 로직 우회.
	//   3) scoreRuleSelect — AHP 가중치 기반 L1/L2/L3/S3 점수 합산. 최고점 tier 선택.
	//      동점은 L2 > L3 > L1 > S3 순으로 폴백한다(L1 단독 승격 방지).
	//   4) (호환) hasScoreSignals(workload.keti.io/* 등) 가 있으면 기존 selectStorageClass
	//      점수 로직을 보조 경로로 사용한다.
	//   5) 위 모든 단계에 입력이 없으면 default L2(storage-l2).
	var (
		className       string
		selectionReason string
		selectionDebug  string
	)
	switch {
	case existingFinalTierFromPVC(pvc) != "":
		existingTier := existingFinalTierFromPVC(pvc)
		className = storageClassByTier(existingTier)
		selectionReason = buildTierReason("existing-tier-preserved", existingTier, className,
			tierScores{}, nil, fmt.Sprintf("preserve existing tier=%s (no override)", existingTier))
		selectionDebug = "existing-tier-preserved"
	default:
		if hardTier, hardReason, ok := hardRuleSelect(pvc); ok {
			className = storageClassByTier(hardTier)
			selectionReason = buildTierReason("hard-rule", hardTier, className, tierScores{}, nil, hardReason)
			selectionDebug = "hard-rule"
			break
		}
		if scoreTier, contribs, scores, ok := scoreRuleSelect(pvc); ok {
			className = storageClassByTier(scoreTier)
			selectionReason = buildTierReason("score-rule", scoreTier, className, scores, contribs, "")
			selectionDebug = "score-rule"
			break
		}
		if hasScoreSignals(pvc) {
			legacyClass, legacyReason, legacyDebug := h.selectStorageClass(pvc)
			if strings.TrimSpace(legacyClass) == "" {
				legacyClass = storageClassL2
				legacyReason = "legacy-score empty -> L2 fallback"
				legacyDebug = "legacy-score-empty"
			}
			legacyTier := storageClassToTier(legacyClass)
			className = legacyClass
			selectionReason = buildTierReason("score-rule", legacyTier, legacyClass, tierScores{}, nil,
				fmt.Sprintf("legacy-score(%s)", legacyReason))
			selectionDebug = "legacy-score:" + legacyDebug
			break
		}
		className = storageClassL2
		selectionReason = buildTierReason("default-l2", tierL2, storageClassL2, tierScores{}, nil, "no input")
		selectionDebug = "default-l2"
	}
	tier := storageClassToTier(className)
	log.Printf("[Webhook][PVC] %s/%s storageClass selected=%q tier=%q reason=%s debug=%s",
		pvc.Namespace, pvc.Name, className, tier, selectionReason, selectionDebug)

	existing := ""
	if pvc.Spec.StorageClassName != nil {
		existing = strings.TrimSpace(*pvc.Spec.StorageClassName)
	}

	var patches []patchOperation

	switch {
	case existing == "":
		log.Printf("[Webhook][PVC] %s/%s storageClassName: <empty> -> %q (tier=%s, op=add)",
			pvc.Namespace, pvc.Name, className, tier)
		patches = append(patches, patchOperation{
			Op:    "add",
			Path:  "/spec/storageClassName",
			Value: className,
		})
	case existing == className:
		log.Printf("[Webhook][PVC] %s/%s storageClassName already %q (tier=%s, op=skip)",
			pvc.Namespace, pvc.Name, className, tier)
	case isLegacyStorageClassValue(existing):
		// 기존 storage-burst/performance/capacity/archive → L1~S3로 normalize
		log.Printf("[Webhook][PVC] %s/%s storageClassName legacy: %q -> %q (tier=%s, op=replace)",
			pvc.Namespace, pvc.Name, existing, className, tier)
		patches = append(patches, patchOperation{
			Op:    "replace",
			Path:  "/spec/storageClassName",
			Value: className,
		})
	case h.isReplaceableStorageClass(existing):
		log.Printf("[Webhook][PVC] %s/%s storageClassName: %q -> %q (tier=%s, op=replace)",
			pvc.Namespace, pvc.Name, existing, className, tier)
		patches = append(patches, patchOperation{
			Op:    "replace",
			Path:  "/spec/storageClassName",
			Value: className,
		})
	default:
		log.Printf("[Webhook][PVC] %s/%s storageClassName keep %q (target=%q, tier=%s, reason=not-replaceable)",
			pvc.Namespace, pvc.Name, existing, className, tier)
	}

	patches = append(patches, h.pvcKetiMetadataPatches(pvc, tier, className, selectionReason)...)
	patches = append(patches, h.buildPVCStageExecutionPlanPatches(pvc, h.lookupStageExecutionPlanFromMetadata(pvc.Labels, pvc.Annotations))...)

	// TODO(미정, JIRA-미정): node label 기반 storage locality와 연동해 tier 선택을 개선한다.
	// TODO(미정, JIRA-미정): Gluesys CSI provisioner 및 backend pool 정책 매핑 확장.
	return patches
}

func (h *MutationHandler) lookupStageExecutionPlanFromMetadata(labels, annotations map[string]string) *stageExecutionPlan {
	if h == nil || strings.TrimSpace(h.config.PlanAPIBaseURL) == "" {
		return nil
	}
	runID := strings.TrimSpace(getMetadataValueFromMaps(labels, annotations, "run_id"))
	targetStage := strings.TrimSpace(getMetadataValueFromMaps(labels, annotations, "target_stage"))
	if runID == "" || targetStage == "" {
		return nil
	}
	endpoint := strings.TrimRight(h.config.PlanAPIBaseURL, "/") + "/api/v1/stage-execution-plans"
	values := url.Values{}
	values.Set("run_id", runID)
	values.Set("target_stage", targetStage)

	req, err := http.NewRequest(http.MethodGet, endpoint+"?"+values.Encode(), nil)
	if err != nil {
		log.Printf("[Webhook] StageExecutionPlan request build failed: %v", err)
		return nil
	}
	resp, err := h.httpClient.Do(req)
	if err != nil {
		log.Printf("[Webhook] StageExecutionPlan lookup failed: run_id=%s target_stage=%s err=%v", runID, targetStage, err)
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var plan stageExecutionPlan
	if err := json.NewDecoder(resp.Body).Decode(&plan); err != nil {
		log.Printf("[Webhook] StageExecutionPlan decode failed: %v", err)
		return nil
	}
	return &plan
}

func (h *MutationHandler) buildPodStageExecutionPlanPatches(pod *corev1.Pod, plan *stageExecutionPlan) []patchOperation {
	if pod == nil || plan == nil {
		return nil
	}
	var patches []patchOperation
	if len(plan.ResourceRequests) > 0 {
		for idx := range pod.Spec.Containers {
			for name, value := range plan.ResourceRequests {
				if strings.TrimSpace(value) == "" {
					continue
				}
				path := fmt.Sprintf("/spec/containers/%d/resources/requests/%s", idx, jsonPointerEscape(strings.ToLower(name)))
				patches = append(patches, patchOperation{Op: "add", Path: path, Value: value})
			}
		}
	}
	if len(plan.NodeSelector) > 0 {
		if pod.Spec.NodeSelector == nil {
			patches = append(patches, patchOperation{Op: "add", Path: "/spec/nodeSelector", Value: plan.NodeSelector})
		} else {
			for key, value := range plan.NodeSelector {
				patches = append(patches, patchOperation{Op: "add", Path: "/spec/nodeSelector/" + jsonPointerEscape(key), Value: value})
			}
		}
	}
	if len(plan.Affinity) > 0 {
		patches = append(patches, patchOperation{Op: "add", Path: "/spec/affinity", Value: plan.Affinity})
	}
	patches = append(patches, addMetadataMapPatches("/metadata/labels", pod.Labels, map[string]string{
		"kueue.x-k8s.io/queue-name": plan.QueueLabel,
	})...)
	mergedAnnotations := map[string]string{}
	for key, value := range plan.StorageAnnotations {
		mergedAnnotations[key] = value
	}
	for key, value := range plan.PolicyAnnotations {
		mergedAnnotations[key] = value
	}
	patches = append(patches, addMetadataMapPatches("/metadata/annotations", pod.Annotations, mergedAnnotations)...)
	return patches
}

func (h *MutationHandler) buildPVCStageExecutionPlanPatches(pvc *corev1.PersistentVolumeClaim, plan *stageExecutionPlan) []patchOperation {
	if pvc == nil || plan == nil {
		return nil
	}
	mergedAnnotations := map[string]string{}
	for key, value := range plan.StorageAnnotations {
		mergedAnnotations[key] = value
	}
	for key, value := range plan.PolicyAnnotations {
		mergedAnnotations[key] = value
	}
	return addMetadataMapPatches("/metadata/annotations", pvc.Annotations, mergedAnnotations)
}

func addMetadataMapPatches(basePath string, existing map[string]string, desired map[string]string) []patchOperation {
	if len(desired) == 0 {
		return nil
	}
	var patches []patchOperation
	filtered := map[string]string{}
	for key, value := range desired {
		if strings.TrimSpace(key) == "" || strings.TrimSpace(value) == "" {
			continue
		}
		filtered[key] = value
	}
	if len(filtered) == 0 {
		return nil
	}
	if existing == nil {
		patches = append(patches, patchOperation{Op: "add", Path: basePath, Value: filtered})
		return patches
	}
	for key, value := range filtered {
		op := "add"
		if _, ok := existing[key]; ok {
			op = "replace"
		}
		patches = append(patches, patchOperation{
			Op:    op,
			Path:  basePath + "/" + jsonPointerEscape(key),
			Value: value,
		})
	}
	return patches
}

func (h *MutationHandler) isReplaceableStorageClass(name string) bool {
	name = strings.TrimSpace(name)
	if name == "" {
		return false
	}
	for _, c := range h.config.ReplaceableStorageClasses {
		if strings.TrimSpace(c) == name {
			return true
		}
	}
	return false
}

func jsonPointerEscape(s string) string {
	// RFC 6901: "~" -> "~0", "/" -> "~1"
	s = strings.ReplaceAll(s, "~", "~0")
	s = strings.ReplaceAll(s, "/", "~1")
	return s
}

func getMetadataValueFromMaps(labels, annotations map[string]string, keys ...string) string {
	for _, key := range keys {
		if annotations != nil {
			if v, ok := annotations[key]; ok && strings.TrimSpace(v) != "" {
				return v
			}
		}
		if labels != nil {
			if v, ok := labels[key]; ok && strings.TrimSpace(v) != "" {
				return v
			}
		}
	}
	return ""
}

func hasCheckpointPath(labels, annotations map[string]string) bool {
	return strings.TrimSpace(getMetadataValueFromMaps(labels, annotations, checkpointPathKey1, checkpointPathKey2)) != ""
}

func defaultStageForTier(tier string) string {
	// 입력은 L1~S3 (또는 legacy burst/performance/capacity/archive) 모두 허용.
	// 내부 비교는 normalize 결과(L1/L2/L3/S3)로 일치시킨다.
	normalized, _ := normalizeTier(tier)
	switch normalized {
	case tierL2:
		return "train"
	case tierL1:
		return "preprocess"
	case tierL3:
		return "inference"
	default:
		return "default"
	}
}

func normalizeFramework(raw string) string {
	return strings.ToLower(strings.TrimSpace(raw))
}

func tierFromFramework(framework, stage string, gpuCount int) string {
	fw := normalizeFramework(framework)
	st := strings.ToLower(strings.TrimSpace(stage))

	switch fw {
	case "pytorch", "torch", "tensorflow":
		if st == "train" || gpuCount > 0 {
			return tierL2
		}
		if st == "inference" {
			return tierL3
		}
	case "triton", "onnxruntime":
		return tierL3
	case "spark", "airflow":
		return tierL1
	}

	return ""
}

func selectTierFromMetadataMaps(labels, annotations map[string]string) string {
	// 1) explicit tier override
	if rawTier := getMetadataValueFromMaps(labels, annotations, storageTierAnnotation); strings.TrimSpace(rawTier) != "" {
		tier, _ := normalizeTier(rawTier)
		if tier != "" {
			return tier
		}
	}

	stage := strings.ToLower(strings.TrimSpace(getMetadataValueFromMaps(labels, annotations, metadataStageLabel, metadataStageAnnotation, workloadStageLabel)))
	gpuCount := parseGPUCount(getMetadataValueFromMaps(labels, annotations, metadataGPUCountLabel, metadataGPUCountLabelAlt, metadataGPUCountAnnotation))
	framework := getMetadataValueFromMaps(labels, annotations, workloadFrameworkLabel, metadataFrameworkLabel, metadataFrameworkAnnotation)

	// 2) framework-aware tier decision
	if tier := tierFromFramework(framework, stage, gpuCount); tier != "" {
		return tier
	}

	// 3) existing stage/gpu rules
	if stage == "train" && gpuCount > 0 {
		return tierL2
	}
	if stage == "preprocess" {
		return tierL1
	}
	if stage == "inference" {
		return tierL3
	}
	return tierS3
}

func storageClassByTier(tier string) string {
	// 입력은 L1~S3 또는 legacy(burst/performance/capacity/archive) 모두 허용.
	// 알 수 없는 값은 S3(아카이브)로 폴백한다.
	normalized, sc := normalizeTier(tier)
	if normalized == "" {
		return storageClassS3
	}
	return sc
}

func workloadTypeForStage(stage string) string {
	switch strings.ToLower(strings.TrimSpace(stage)) {
	case "train":
		return "training"
	case "preprocess":
		return "preprocessing"
	case "inference":
		return "inference"
	default:
		return "default"
	}
}

// buildKetiMetadataPatches: Pod/PVC 메타데이터에 KETI 표준 키를 merge 방식으로 주입
// - 기존 값이 있으면 유지(기본)
// - 단, 내부 정책으로 강제해야 하는 값(selected tier, tier-hint, checkpoint)은 override 가능
func buildKetiMetadataPatches(existingLabels, existingAnnotations map[string]string, tier string) []patchOperation {
	var patches []patchOperation

	// stage 입력은 tier 선택에 사용하던 "stage"/"ai-storage/stage"에서 가져옴.
	stageInput := strings.ToLower(strings.TrimSpace(getMetadataValueFromMaps(existingLabels, existingAnnotations, metadataStageLabel, metadataStageAnnotation, workloadStageLabel)))
	stage := stageInput
	if stage != "train" && stage != "preprocess" && stage != "inference" {
		stage = defaultStageForTier(tier)
	}
	workloadType := workloadTypeForStage(stage)
	framework := strings.ToLower(strings.TrimSpace(getMetadataValueFromMaps(existingLabels, existingAnnotations, workloadFrameworkLabel, metadataFrameworkLabel, metadataFrameworkAnnotation)))
	if framework != "" {
		if stage == "train" {
			workloadType = "training"
		} else if stage == "inference" {
			workloadType = "inference"
		}
	}

	checkpointVal := "false"
	if hasCheckpointPath(existingLabels, existingAnnotations) {
		checkpointVal = "true"
	}

	// annotations: 강제/기본 값 준비
	desiredAnnotations := map[string]string{
		// 강제 (tier 기반)
		selectedTierAnnotation: tier,
		tierHintAnnotation:     tier,
		checkpointAnnotation:   checkpointVal,
		// 기본 (없으면 채움)
		datasetSizeAnnotation:   getMetadataValueFromMaps(existingLabels, existingAnnotations, datasetSizeAnnotation),
		prefetchAnnotation:      getMetadataValueFromMaps(existingLabels, existingAnnotations, prefetchAnnotation),
		latencyAnnotation:       getMetadataValueFromMaps(existingLabels, existingAnnotations, latencyAnnotation),
		archivePolicyAnnotation: getMetadataValueFromMaps(existingLabels, existingAnnotations, archivePolicyAnnotation),
	}

	if strings.TrimSpace(desiredAnnotations[datasetSizeAnnotation]) == "" {
		desiredAnnotations[datasetSizeAnnotation] = defaultDatasetSize
	}
	if strings.TrimSpace(desiredAnnotations[prefetchAnnotation]) == "" {
		desiredAnnotations[prefetchAnnotation] = defaultPrefetch
	}
	if strings.TrimSpace(desiredAnnotations[latencyAnnotation]) == "" {
		desiredAnnotations[latencyAnnotation] = defaultLatencyMs
	}
	if strings.TrimSpace(desiredAnnotations[archivePolicyAnnotation]) == "" {
		desiredAnnotations[archivePolicyAnnotation] = defaultArchivePolicy
	}

	// labels: 강제/기본 값 준비
	desiredLabels := map[string]string{
		selectedTierLabel:  tier,         // 강제
		workloadStageLabel: stage,        // 값이 없을 때만 add
		workloadTypeLabel:  workloadType, // 값이 없을 때만 add
	}

	// ── labels 주입 ──
	if existingLabels == nil {
		patches = append(patches, patchOperation{
			Op:   "add",
			Path: "/metadata/labels",
			Value: map[string]string{
				selectedTierLabel:  tier,
				workloadStageLabel: stage,
				workloadTypeLabel:  workloadType,
			},
		})
	} else {
		// workload stage/type는 "없을 때만" add
		if v, ok := existingLabels[workloadStageLabel]; !ok || strings.TrimSpace(v) == "" {
			patches = append(patches, patchOperation{
				Op:    "add",
				Path:  "/metadata/labels/" + jsonPointerEscape(workloadStageLabel),
				Value: stage,
			})
		}
		if v, ok := existingLabels[workloadTypeLabel]; !ok || strings.TrimSpace(v) == "" {
			patches = append(patches, patchOperation{
				Op:    "add",
				Path:  "/metadata/labels/" + jsonPointerEscape(workloadTypeLabel),
				Value: workloadType,
			})
		}

		// selected tier label은 강제 override 가능
		if v, ok := existingLabels[selectedTierLabel]; !ok {
			patches = append(patches, patchOperation{
				Op:    "add",
				Path:  "/metadata/labels/" + jsonPointerEscape(selectedTierLabel),
				Value: desiredLabels[selectedTierLabel],
			})
		} else if strings.TrimSpace(v) != desiredLabels[selectedTierLabel] {
			patches = append(patches, patchOperation{
				Op:    "replace",
				Path:  "/metadata/labels/" + jsonPointerEscape(selectedTierLabel),
				Value: desiredLabels[selectedTierLabel],
			})
		}
	}

	// ── annotations 주입 ──
	if existingAnnotations == nil {
		patches = append(patches, patchOperation{
			Op:    "add",
			Path:  "/metadata/annotations",
			Value: desiredAnnotations,
		})
	} else {
		// forced keys: selectedTierAnnotation, tierHintAnnotation, checkpointAnnotation
		for _, key := range []string{selectedTierAnnotation, tierHintAnnotation, checkpointAnnotation} {
			if v, ok := existingAnnotations[key]; !ok {
				patches = append(patches, patchOperation{
					Op:    "add",
					Path:  "/metadata/annotations/" + jsonPointerEscape(key),
					Value: desiredAnnotations[key],
				})
			} else if strings.TrimSpace(v) != desiredAnnotations[key] {
				patches = append(patches, patchOperation{
					Op:    "replace",
					Path:  "/metadata/annotations/" + jsonPointerEscape(key),
					Value: desiredAnnotations[key],
				})
			}
		}

		// non-forced keys: dataset-size, prefetch, latency, archive-policy
		for _, key := range []string{datasetSizeAnnotation, prefetchAnnotation, latencyAnnotation, archivePolicyAnnotation} {
			if v, ok := existingAnnotations[key]; !ok || strings.TrimSpace(v) == "" {
				patches = append(patches, patchOperation{
					Op:    "add",
					Path:  "/metadata/annotations/" + jsonPointerEscape(key),
					Value: desiredAnnotations[key],
				})
			}
		}
	}

	return patches
}

// pvcKetiMetadataPatches는 PVC에 KETI 표준 라벨/어노테이션을 주입한다.
//
// Pod와 달리 PVC는 기존에 박혀 있는 selected-tier / selected-storage-class /
// tier-hint 가 이미 L1~S3 표준이면 보존하고, 기존 값이 burst/performance/
// capacity/archive 같은 legacy면 normalize 결과(L1~S3)로 교체한다.
//
// Parameters:
//   - pvc: 패치 대상 PVC.
//   - tier: 이번 admission에서 선택한 tier(L1~S3).
//   - className: 이번 admission에서 선택한 StorageClass 이름(storage-l1~s3).
//   - reason: tier 선택 이유(로깅/디버깅 용도; tier-reason annotation에 기록).
//
// Returns:
//   - []patchOperation: JSON Patch 연산 목록.
func (h *MutationHandler) pvcKetiMetadataPatches(pvc *corev1.PersistentVolumeClaim, tier, className, reason string) []patchOperation {
	return buildPVCKetiMetadataPatches(pvc.Labels, pvc.Annotations, tier, className, reason)
}

// buildPVCKetiMetadataPatches는 PVC용 KETI 표준 metadata 주입 로직이다.
//
// 동작 규칙(요청사항):
//  1. tier-hint / selected-tier / selected-storage-class:
//     - 기존 값이 L1~S3 (또는 storage-l1~s3) 이면 보존(patch 없음).
//     - 기존 값이 burst/performance/capacity/archive (또는 storage-*) 이면 L1~S3로 normalize.
//     - 기존 값이 없으면 이번 admission 결과로 add.
//  2. tier-reason: 이번 admission의 reason 값으로 항상 갱신(force).
//  3. checkpoint / dataset-size / prefetch / latency / archive-policy: 기존 로직 유지.
func buildPVCKetiMetadataPatches(existingLabels, existingAnnotations map[string]string, tier, className, reason string) []patchOperation {
	var patches []patchOperation

	stageInput := strings.ToLower(strings.TrimSpace(getMetadataValueFromMaps(existingLabels, existingAnnotations, metadataStageLabel, metadataStageAnnotation, workloadStageLabel)))
	stage := stageInput
	if stage != "train" && stage != "preprocess" && stage != "inference" {
		stage = defaultStageForTier(tier)
	}
	workloadType := workloadTypeForStage(stage)
	framework := strings.ToLower(strings.TrimSpace(getMetadataValueFromMaps(existingLabels, existingAnnotations, workloadFrameworkLabel, metadataFrameworkLabel, metadataFrameworkAnnotation)))
	if framework != "" {
		if stage == "train" {
			workloadType = "training"
		} else if stage == "inference" {
			workloadType = "inference"
		}
	}

	checkpointVal := "false"
	if hasCheckpointPath(existingLabels, existingAnnotations) {
		checkpointVal = "true"
	}

	desiredAnnotations := map[string]string{
		selectedTierAnnotation:         tier,
		selectedStorageClassAnnotation: className,
		tierHintAnnotation:             tier,
		tierReasonAnnotation:           reason,
		checkpointAnnotation:           checkpointVal,
		datasetSizeAnnotation:          getMetadataValueFromMaps(existingLabels, existingAnnotations, datasetSizeAnnotation),
		prefetchAnnotation:             getMetadataValueFromMaps(existingLabels, existingAnnotations, prefetchAnnotation),
		latencyAnnotation:              getMetadataValueFromMaps(existingLabels, existingAnnotations, latencyAnnotation),
		archivePolicyAnnotation:        getMetadataValueFromMaps(existingLabels, existingAnnotations, archivePolicyAnnotation),
	}
	if strings.TrimSpace(desiredAnnotations[datasetSizeAnnotation]) == "" {
		desiredAnnotations[datasetSizeAnnotation] = defaultDatasetSize
	}
	if strings.TrimSpace(desiredAnnotations[prefetchAnnotation]) == "" {
		desiredAnnotations[prefetchAnnotation] = defaultPrefetch
	}
	if strings.TrimSpace(desiredAnnotations[latencyAnnotation]) == "" {
		desiredAnnotations[latencyAnnotation] = defaultLatencyMs
	}
	if strings.TrimSpace(desiredAnnotations[archivePolicyAnnotation]) == "" {
		desiredAnnotations[archivePolicyAnnotation] = defaultArchivePolicy
	}

	desiredLabels := map[string]string{
		selectedTierLabel:  tier,
		workloadStageLabel: stage,
		workloadTypeLabel:  workloadType,
	}

	// tierPreservedAnnotationValue는 기존 annotation 값에 대한 preservation/normalization 규칙을 적용해
	// 최종적으로 박아야 할 값을 반환한다. 두 번째 반환값은 patch가 필요한지 여부.
	tierPreservedAnnotationValue := func(existing, desired string, isStorageClass bool) (string, bool) {
		existing = strings.TrimSpace(existing)
		if existing == "" {
			return desired, true
		}
		if isStorageClass {
			if isFinalStorageClassValue(existing) {
				return existing, existing != desired && !isFinalStorageClassValue(existing) // preserve final SC (no patch)
			}
			if isLegacyStorageClassValue(existing) {
				normalized := storageClassByTier(storageClassToTier(existing))
				return normalized, normalized != existing
			}
			// 비표준 값은 손대지 않는다.
			return existing, false
		}
		// tier-hint / selected-tier
		if isFinalTierValue(existing) {
			return existing, false
		}
		if normalized, _ := normalizeTier(existing); normalized != "" {
			return normalized, normalized != existing
		}
		return existing, false
	}

	// labels 주입
	if existingLabels == nil {
		patches = append(patches, patchOperation{
			Op:    "add",
			Path:  "/metadata/labels",
			Value: desiredLabels,
		})
	} else {
		if v, ok := existingLabels[workloadStageLabel]; !ok || strings.TrimSpace(v) == "" {
			patches = append(patches, patchOperation{
				Op:    "add",
				Path:  "/metadata/labels/" + jsonPointerEscape(workloadStageLabel),
				Value: stage,
			})
		}
		if v, ok := existingLabels[workloadTypeLabel]; !ok || strings.TrimSpace(v) == "" {
			patches = append(patches, patchOperation{
				Op:    "add",
				Path:  "/metadata/labels/" + jsonPointerEscape(workloadTypeLabel),
				Value: workloadType,
			})
		}

		// selected-tier label: preserve final, normalize legacy, add if absent
		if v, ok := existingLabels[selectedTierLabel]; !ok || strings.TrimSpace(v) == "" {
			patches = append(patches, patchOperation{
				Op:    "add",
				Path:  "/metadata/labels/" + jsonPointerEscape(selectedTierLabel),
				Value: desiredLabels[selectedTierLabel],
			})
		} else if !isFinalTierValue(strings.TrimSpace(v)) {
			if normalized, _ := normalizeTier(v); normalized != "" && normalized != strings.TrimSpace(v) {
				patches = append(patches, patchOperation{
					Op:    "replace",
					Path:  "/metadata/labels/" + jsonPointerEscape(selectedTierLabel),
					Value: normalized,
				})
			}
		}
	}

	// annotations 주입
	if existingAnnotations == nil {
		patches = append(patches, patchOperation{
			Op:    "add",
			Path:  "/metadata/annotations",
			Value: desiredAnnotations,
		})
		return patches
	}

	// preservation/normalization 적용 키: selected-tier, tier-hint, selected-storage-class
	type preservedKey struct {
		key            string
		desired        string
		isStorageClass bool
	}
	preservedKeys := []preservedKey{
		{selectedTierAnnotation, tier, false},
		{tierHintAnnotation, tier, false},
		{selectedStorageClassAnnotation, className, true},
	}
	for _, pk := range preservedKeys {
		existing, ok := existingAnnotations[pk.key]
		if !ok {
			patches = append(patches, patchOperation{
				Op:    "add",
				Path:  "/metadata/annotations/" + jsonPointerEscape(pk.key),
				Value: pk.desired,
			})
			continue
		}
		newVal, shouldPatch := tierPreservedAnnotationValue(existing, pk.desired, pk.isStorageClass)
		if !shouldPatch {
			continue
		}
		patches = append(patches, patchOperation{
			Op:    "replace",
			Path:  "/metadata/annotations/" + jsonPointerEscape(pk.key),
			Value: newVal,
		})
	}

	// tier-reason: 매 admission마다 최신 reason으로 갱신(보존하지 않음).
	if v, ok := existingAnnotations[tierReasonAnnotation]; !ok {
		patches = append(patches, patchOperation{
			Op:    "add",
			Path:  "/metadata/annotations/" + jsonPointerEscape(tierReasonAnnotation),
			Value: reason,
		})
	} else if strings.TrimSpace(v) != reason {
		patches = append(patches, patchOperation{
			Op:    "replace",
			Path:  "/metadata/annotations/" + jsonPointerEscape(tierReasonAnnotation),
			Value: reason,
		})
	}

	// checkpoint: 기존 로직과 동일하게 강제 갱신
	if v, ok := existingAnnotations[checkpointAnnotation]; !ok {
		patches = append(patches, patchOperation{
			Op:    "add",
			Path:  "/metadata/annotations/" + jsonPointerEscape(checkpointAnnotation),
			Value: desiredAnnotations[checkpointAnnotation],
		})
	} else if strings.TrimSpace(v) != desiredAnnotations[checkpointAnnotation] {
		patches = append(patches, patchOperation{
			Op:    "replace",
			Path:  "/metadata/annotations/" + jsonPointerEscape(checkpointAnnotation),
			Value: desiredAnnotations[checkpointAnnotation],
		})
	}

	// dataset-size / prefetch / latency / archive-policy: 없을 때만 add
	for _, key := range []string{datasetSizeAnnotation, prefetchAnnotation, latencyAnnotation, archivePolicyAnnotation} {
		if v, ok := existingAnnotations[key]; !ok || strings.TrimSpace(v) == "" {
			patches = append(patches, patchOperation{
				Op:    "add",
				Path:  "/metadata/annotations/" + jsonPointerEscape(key),
				Value: desiredAnnotations[key],
			})
		}
	}

	return patches
}

func selectTierForPod(pod *corev1.Pod) string {
	return selectTierFromMetadataMaps(pod.Labels, pod.Annotations)
}

// pvcTierMetadataPatches: ai-storage/selected-tier 및 라벨 주입(없을 때만 add)
func (h *MutationHandler) pvcTierMetadataPatches(pvc *corev1.PersistentVolumeClaim, tier string) []patchOperation {
	var patches []patchOperation
	if pvc.Annotations == nil {
		patches = append(patches, patchOperation{
			Op:   "add",
			Path: "/metadata/annotations",
			Value: map[string]string{
				selectedTierAnnotation: tier,
			},
		})
	} else if _, ok := pvc.Annotations[selectedTierAnnotation]; !ok {
		patches = append(patches, patchOperation{
			Op:    "add",
			Path:  "/metadata/annotations/ai-storage~1selected-tier",
			Value: tier,
		})
	}

	if pvc.Labels == nil {
		patches = append(patches, patchOperation{
			Op:   "add",
			Path: "/metadata/labels",
			Value: map[string]string{
				selectedTierLabel: tier,
			},
		})
	} else if _, ok := pvc.Labels[selectedTierLabel]; !ok {
		patches = append(patches, patchOperation{
			Op:    "add",
			Path:  "/metadata/labels/ai-storage-selected-tier",
			Value: tier,
		})
	}
	return patches
}

func selectStorageTierAndClass(pvc *corev1.PersistentVolumeClaim) (string, string) {
	tier := selectTierFromMetadataMaps(pvc.Labels, pvc.Annotations)
	return tier, storageClassByTier(tier)
}

// storageClassToTier는 StorageClass 이름을 표준 tier(L1~S3)로 역매핑한다.
// 기존 storage-burst/performance/capacity/archive 명도 호환 입력으로 인식한다.
// 알 수 없는 값은 S3로 폴백한다.
func storageClassToTier(storageClassName string) string {
	switch strings.ToLower(strings.TrimSpace(storageClassName)) {
	case storageClassL1, "storage-burst", "storage-cache":
		return tierL1
	case storageClassL2, "storage-performance":
		return tierL2
	case storageClassL3, "storage-capacity":
		return tierL3
	case storageClassS3, "storage-archive":
		return tierS3
	default:
		return tierS3
	}
}

// =============================================================================
// StorageClass selection (filter + score)
// =============================================================================

// storage size policy config placeholders.
// NOTE: 요청사항에 따라 requested_storage_size 기반 필터/스코어링은
// 현재는 비활성(주석) 상태로 둡니다.
type byteRange struct {
	MinBytes uint64
	MaxBytes uint64
}

type storageSizePolicy struct {
	Enabled     bool
	Recommended *byteRange
	Usable      *byteRange
}

var storageClassSizePolicies = map[string]storageSizePolicy{
	// TODO(미정, JIRA-미정): recommended/usable range 값을 채우면 요청 storage 크기 기반 필터/스코어 활성화.
	storageClassL1: {
		Enabled:     false,
		Recommended: nil,
		Usable:      nil,
	},
	storageClassL2: {
		Enabled:     false,
		Recommended: nil,
		Usable:      nil,
	},
	storageClassL3: {
		Enabled:     false,
		Recommended: nil,
		Usable:      nil,
	},
	storageClassS3: {
		Enabled:     false,
		Recommended: nil,
		Usable:      nil,
	},
}

// storage access mode policy placeholders.
// NOTE: 값이 비어 있으면 accessMode 필터링을 스킵합니다.
var storageClassSupportedAccessModes = map[string][]corev1.PersistentVolumeAccessMode{
	// TODO(미정, JIRA-미정): 실제로 provision 가능한 accessMode를 SC별로 채운다.
	// 예) storageClassSupportedAccessModes["storage-s3"] = []corev1.PersistentVolumeAccessMode{corev1.ReadOnlyMany, corev1.ReadWriteOnce}
}

type extractedPodVolume struct {
	mountPath      string
	mountPathKnown bool
	readOnly       bool
	readOnlyKnown  bool
}

// NOTE: 요청사항으로 인해 PVC -> Pod 역조회 로직은 createPVCPatch에서 제거됐습니다.
// (findPodReferencingPVC / extractPodVolume 등은 더 이상 호출되지 않습니다.)

func normalizeWorkloadType(raw string) (string, bool) {
	s := strings.ToLower(strings.TrimSpace(raw))
	switch s {
	case "preprocess", "preprocessing":
		return "preprocess", true
	case "train", "training":
		return "train", true
	case "infer", "inference":
		return "infer", true
	default:
		return "", false
	}
}

func extractWorkloadTypeFromPVC(pvc *corev1.PersistentVolumeClaim) (string, bool) {
	if pvc == nil {
		return "", false
	}
	// 우선 workload.keti.io/type (Pod/PVC에서 KETI metadata로 주입되는 값)
	if raw := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, workloadTypeAnnotation, workloadTypeLabel); strings.TrimSpace(raw) != "" {
		if wt, ok := normalizeWorkloadType(raw); ok {
			return wt, true
		}
	}

	// 없으면 stage(train/preprocess/inference) 기반으로 추정 (명시적 입력이 없을 때만 사용)
	stage := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, metadataStageLabel, metadataStageAnnotation, workloadStageLabel)
	switch strings.ToLower(strings.TrimSpace(stage)) {
	case "train":
		return "train", true
	case "preprocess":
		return "preprocess", true
	case "inference":
		return "infer", true
	default:
		return "", false
	}
}

func extractFrameworkFromPVC(pvc *corev1.PersistentVolumeClaim) (string, bool) {
	if pvc == nil {
		return "", false
	}
	raw := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, workloadFrameworkLabel, metadataFrameworkLabel, metadataFrameworkAnnotation)
	raw = normalizeFramework(raw)
	if raw == "" {
		return "", false
	}
	return raw, true
}

func extractGPUCountFromPVC(pvc *corev1.PersistentVolumeClaim) (int, bool) {
	if pvc == nil {
		return 0, false
	}
	raw := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, metadataGPUCountLabel, metadataGPUCountLabelAlt, metadataGPUCountAnnotation)
	if strings.TrimSpace(raw) == "" {
		return 0, false
	}
	return parseGPUCount(raw), true
}

func extractWorkloadKindFromPVC(pvc *corev1.PersistentVolumeClaim) (string, bool) {
	if pvc == nil {
		return "", false
	}
	raw := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, workloadKindLabel)
	if strings.TrimSpace(raw) == "" {
		return "", false
	}
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "job":
		return "Job", true
	case "cronjob", "cron_job", "cron-job":
		return "CronJob", true
	case "deployment":
		return "Deployment", true
	case "statefulset":
		return "StatefulSet", true
	default:
		return "", false
	}
}

func extractMountPathFromPVC(pvc *corev1.PersistentVolumeClaim) (string, bool) {
	if pvc == nil {
		return "", false
	}
	raw := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, mountPathLabel)
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", false
	}
	return raw, true
}

func extractReadOnlyFromPVC(pvc *corev1.PersistentVolumeClaim) (bool, bool) {
	if pvc == nil {
		return false, false
	}
	raw := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, readOnlyLabel)
	raw = strings.TrimSpace(strings.ToLower(raw))
	if raw == "" {
		return false, false
	}
	switch raw {
	case "true", "1", "yes", "y":
		return true, true
	case "false", "0", "no", "n":
		return false, true
	default:
		return false, false
	}
}

func extractPVCCountFromPVC(pvc *corev1.PersistentVolumeClaim) (int, bool) {
	if pvc == nil {
		return 0, false
	}
	raw := strings.TrimSpace(getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, pvcCountLabel))
	if raw == "" {
		return 0, false
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		return 0, false
	}
	return n, true
}

func extractReplicaCountFromPVC(pvc *corev1.PersistentVolumeClaim) (int32, bool) {
	if pvc == nil {
		return 0, false
	}
	raw := strings.TrimSpace(getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, replicaCountLabel))
	if raw == "" {
		return 0, false
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		return 0, false
	}
	return int32(n), true
}

// NOTE: requested gpu_count, volumeMount path, readOnly, workload kind 등은
// Pod 역조회 없이 PVC metadata로부터만 추출합니다.

func (r byteRange) contains(bytes uint64) bool {
	return bytes >= r.MinBytes && bytes <= r.MaxBytes
}

func extractRequestedStorageBytes(pvc *corev1.PersistentVolumeClaim) (uint64, bool) {
	if pvc == nil {
		return 0, false
	}
	if pvc.Spec.Resources.Requests == nil {
		return 0, false
	}
	q, ok := pvc.Spec.Resources.Requests[corev1.ResourceStorage]
	if !ok {
		return 0, false
	}
	v := q.Value()
	if v <= 0 {
		return 0, false
	}
	return uint64(v), true
}

// NOTE: workload kind / mountPath / readOnly / pvc_count / replica 수는
// PVC metadata로부터 직접 추출합니다.

func (h *MutationHandler) selectStorageClass(pvc *corev1.PersistentVolumeClaim) (string, string, string) {
	// 1) SC 후보 목록 (Gluesys 표준 L1/L2/L3/S3 순)
	candidates := []string{storageClassL1, storageClassL2, storageClassL3, storageClassS3}

	// 이전 로직의 explicit override: storage-tier가 있으면 해당 tier의 SC만 후보로 제한
	expTierRaw := getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, storageTierAnnotation)
	expTier, expTierClass := normalizeTier(expTierRaw)
	if strings.TrimSpace(expTier) != "" && strings.TrimSpace(expTierClass) != "" {
		candidates = []string{expTierClass}
	}

	// 2) 입력값 추출
	workloadType, workloadTypeKnown := extractWorkloadTypeFromPVC(pvc)
	framework, frameworkKnown := extractFrameworkFromPVC(pvc)

	gpuCount, gpuCountKnown := extractGPUCountFromPVC(pvc)
	if gpuCount < 0 {
		gpuCount = 0
	}

	// 요청사항: StorageClass 선택은 PVC metadata만 사용한다.
	// workload kind / mountPath / readOnly / pvc_count / replica 수는 PVC에 라벨/어노테이션으로 들어온 값만 사용.
	workloadKind, workloadKindKnown := extractWorkloadKindFromPVC(pvc)
	mountPath, mountPathKnown := extractMountPathFromPVC(pvc)
	readOnly, readOnlyKnown := extractReadOnlyFromPVC(pvc)
	pvcCount, pvcCountKnown := extractPVCCountFromPVC(pvc)
	replicas, replicaKnown := extractReplicaCountFromPVC(pvc)

	// TODO: cpu_request / memory_request 기반 점수화는 이후 단계에서 추가.

	// 3) 필터링
	filtered := make([]string, 0, len(candidates))
	filterDebug := make([]string, 0, len(candidates))

	for _, sc := range candidates {
		// accessModes 필터 (config 미설정이면 스킵)
		if supportedModes, ok := storageClassSupportedAccessModes[sc]; ok && len(supportedModes) > 0 {
			// PVC 요구 accessModes가 모두 지원되어야 한다.
			allSupported := true
			for _, reqMode := range pvc.Spec.AccessModes {
				found := false
				for _, sup := range supportedModes {
					if sup == reqMode {
						found = true
						break
					}
				}
				if !found {
					allSupported = false
					break
				}
			}
			if !allSupported {
				filterDebug = append(filterDebug, fmt.Sprintf("%s filtered(accessMode)", sc))
				continue
			}
		}

		// requested_storage_size 기반 필터링은 현재 비활성(요청사항: 주석처리) 상태입니다.
		// TODO: requested_storage_size 기반 recommended/usable range 필터링 추가
		// (임의 threshold, 추정값 사용 금지)

		filtered = append(filtered, sc)
	}

	if len(filtered) == 0 {
		// 필터로 전부 제외되면 fallback: archive 후보만 사용
		filtered = []string{storageClassS3}
	}

	// 4) 스코어링 (남은 SC만)
	scores := make(map[string]int, len(filtered))
	scoreReasons := make(map[string][]string, len(filtered))

	fwCategory := ""
	if frameworkKnown {
		switch framework {
		case "pytorch", "torch", "tensorflow":
			fwCategory = "learning"
		case "spark", "airflow":
			fwCategory = "pipeline"
		case "triton", "onnxruntime":
			fwCategory = "serving"
		default:
			fwCategory = ""
		}
	}

	getWorkloadTypePts := func(sc string) int {
		if !workloadTypeKnown {
			return 0
		}
		switch workloadType {
		case "preprocess":
			switch sc {
			case storageClassL1:
				return 2
			case storageClassL2, storageClassL3:
				return 1
			default:
				return 0
			}
		case "train":
			switch sc {
			case storageClassL2:
				return 2
			case storageClassL1, storageClassL3:
				return 1
			default:
				return 0
			}
		case "infer":
			switch sc {
			case storageClassL3:
				return 2
			case storageClassL2:
				return 1
			case storageClassL1:
				return 0
			default:
				return 0
			}
		default:
			return 0
		}
	}

	getGPUPoints := func(sc string) int {
		if !gpuCountKnown {
			return 0
		}
		if gpuCount >= 1 {
			switch sc {
			case storageClassL2:
				return 2
			case storageClassL3:
				return 1
			default:
				return 0
			}
		}
		// gpuCount == 0
		switch sc {
		case storageClassL1:
			return 1
		case storageClassL3:
			return 1
		default:
			return 0
		}
	}

	// requested_storage_size 기반 스코어링은 현재 비활성(요청사항: 주석처리) 상태입니다.
	// TODO: requested_storage_size 기반 recommended/usable range 스코어링 추가 예정

	getWorkloadKindPts := func(sc string) int {
		if !workloadKindKnown {
			return 0
		}
		switch workloadKind {
		case "Job":
			switch sc {
			case storageClassL1:
				return 2
			case storageClassL2:
				return 2
			case storageClassL3:
				return 1
			default:
				return 0
			}
		case "CronJob":
			switch sc {
			case storageClassL1:
				return 2
			case storageClassL3:
				return 1
			default:
				return 0
			}
		case "Deployment":
			switch sc {
			case storageClassL3:
				return 2
			case storageClassL2:
				return 1
			default:
				return 0
			}
		case "StatefulSet":
			switch sc {
			case storageClassL3:
				return 2
			case storageClassL1, storageClassL2:
				// burst=1, performance=1
				if sc == storageClassL3 {
					return 0
				}
				if sc == storageClassL1 {
					return 1
				}
				if sc == storageClassL2 {
					return 1
				}
				return 0
			default:
				return 0
			}
		default:
			return 0
		}
	}

	getVolumeMountPts := func(sc string) int {
		if !mountPathKnown {
			return 0
		}
		mp := mountPath
		switch mp {
		case "/cache":
			if sc == storageClassL1 {
				return 2
			}
		case "/input", "/output":
			switch sc {
			case storageClassL1:
				return 2
			case storageClassL3:
				return 1
			}
		case "/checkpoint":
			if sc == storageClassL2 {
				return 2
			}
		case "/model":
			switch sc {
			case storageClassL3:
				return 2
			case storageClassL2:
				return 1
			}
		case "/data", "/dataset":
			switch sc {
			case storageClassL1, storageClassL2, storageClassL3:
				return 1
			}
		default:
			// 기타: 0
		}
		// prefix match (예: /data/xxx)
		if strings.HasPrefix(mp, "/data/") || strings.HasPrefix(mp, "/dataset/") {
			switch sc {
			case storageClassL1, storageClassL2, storageClassL3:
				return 1
			}
		}
		if strings.HasPrefix(mp, "/cache/") {
			if sc == storageClassL1 {
				return 2
			}
		}
		return 0
	}

	getFrameworkPts := func(sc string) int {
		if !frameworkKnown || fwCategory == "" {
			return 0
		}
		switch fwCategory {
		case "learning":
			if sc == storageClassL2 {
				return 2
			}
			if sc == storageClassL3 {
				return 1
			}
		case "pipeline":
			if sc == storageClassL1 {
				return 2
			}
			if sc == storageClassL3 {
				return 1
			}
		case "serving":
			if sc == storageClassL3 {
				return 2
			}
			if sc == storageClassL2 {
				return 1
			}
		}
		return 0
	}

	getReadOnlyPts := func(sc string) int {
		if !readOnlyKnown {
			return 0
		}
		if readOnly {
			if sc == storageClassL3 {
				return 2
			}
			if sc == storageClassS3 {
				return 1
			}
			return 0
		}
		// readOnly == false
		if sc == storageClassL1 {
			return 2
		}
		if sc == storageClassL2 {
			return 1
		}
		return 0
	}

	getPVCPts := func(sc string) int {
		if !pvcCountKnown {
			return 0
		}
		if pvcCount == 1 {
			if sc == storageClassL3 {
				return 1
			}
			return 0
		}
		// pvc_count >= 2
		if sc == storageClassL1 {
			return 2
		}
		if sc == storageClassL2 {
			return 1
		}
		return 0
	}

	getReplicaPts := func(sc string) int {
		if !replicaKnown {
			return 0
		}
		if replicas <= 1 {
			if sc == storageClassL3 {
				return 1
			}
			return 0
		}
		// replicas >= 2
		if sc == storageClassL3 {
			return 2
		}
		return 0
	}

	for _, sc := range filtered {
		totalRaw := 0
		reasons := make([]string, 0, 8)

		// workload_type
		pts := getWorkloadTypePts(sc)
		totalRaw += pts
		if pts > 0 {
			reasons = append(reasons, fmt.Sprintf("workloadType(%s)=%d", workloadType, pts))
		}

		// gpu_count
		pts = getGPUPoints(sc)
		totalRaw += pts
		if pts > 0 && gpuCountKnown {
			reasons = append(reasons, fmt.Sprintf("gpuCount(%d)=%d", gpuCount, pts))
		}

		// requested_storage_size 기반 스코어링은 현재 비활성(요청사항: 주석처리) 상태입니다.

		// workload kind
		pts = getWorkloadKindPts(sc)
		totalRaw += pts
		if pts > 0 && workloadKindKnown {
			reasons = append(reasons, fmt.Sprintf("workloadKind(%s)=%d", workloadKind, pts))
		}

		// volume mount path
		pts = getVolumeMountPts(sc)
		totalRaw += pts
		if pts > 0 && mountPathKnown {
			reasons = append(reasons, fmt.Sprintf("mountPath(%s)=%d", mountPath, pts))
		}

		// framework
		pts = getFrameworkPts(sc)
		totalRaw += pts
		if pts > 0 && frameworkKnown {
			reasons = append(reasons, fmt.Sprintf("framework(%s/%s)=%d", framework, fwCategory, pts))
		}

		// readOnly
		pts = getReadOnlyPts(sc)
		totalRaw += pts
		if pts > 0 && readOnlyKnown {
			reasons = append(reasons, fmt.Sprintf("readOnly(%t)=%d", readOnly, pts))
		}

		// pvc_count
		pts = getPVCPts(sc)
		totalRaw += pts
		if pts > 0 && pvcCountKnown {
			reasons = append(reasons, fmt.Sprintf("pvcCount(%d)=%d", pvcCount, pts))
		}

		// replica 수
		pts = getReplicaPts(sc)
		totalRaw += pts
		if pts > 0 && replicaKnown {
			reasons = append(reasons, fmt.Sprintf("replicas(%d)=%d", replicas, pts))
		}

		// 요청사항: clamp 하지 않고, 각 항목 점수의 합을 총점으로 사용
		scores[sc] = totalRaw
		scoreReasons[sc] = reasons
	}

	maxScore := -1
	top := make([]string, 0, len(filtered))
	for _, sc := range filtered {
		scScore := scores[sc]
		if scScore > maxScore {
			maxScore = scScore
			top = []string{sc}
		} else if scScore == maxScore {
			top = append(top, sc)
		}
	}

	// 5) 동점 처리: workload_type 기반 fallback
	desiredSC := ""
	if workloadTypeKnown {
		switch workloadType {
		case "preprocess":
			desiredSC = storageClassL1
		case "train":
			desiredSC = storageClassL2
		case "infer":
			desiredSC = storageClassL3
		}
	}

	chosen := ""
	for _, sc := range top {
		if desiredSC != "" && sc == desiredSC {
			chosen = sc
			break
		}
	}

	if chosen == "" {
		// workload_type이 없거나 desiredSC가 top에 없으면 archive로 fallback
		for _, sc := range top {
			if sc == storageClassS3 {
				chosen = sc
				break
			}
		}
	}
	if chosen == "" && len(top) > 0 {
		chosen = top[0]
	}

	// 선택 이유/디버그 문자열
	filteredStr := strings.Join(filtered, ",")
	scoresStrParts := make([]string, 0, len(filtered))
	for _, sc := range filtered {
		scoresStrParts = append(scoresStrParts, fmt.Sprintf("%s=%d", sc, scores[sc]))
	}
	scoresStr := strings.Join(scoresStrParts, ",")
	filterDebugStr := strings.Join(filterDebug, ",")

	reason := fmt.Sprintf("workloadType=%s/framework=%s/gpuKnown=%t/gpu=%d/mountPathKnown=%t/mountPath=%s/readOnlyKnown=%t/readOnly=%t/kindKnown=%t/kind=%s/pvcCountKnown=%t/pvcCount=%d/replicaKnown=%t/replicas=%d",
		workloadType, framework, gpuCountKnown, gpuCount, mountPathKnown, mountPath, readOnlyKnown, readOnly, workloadKindKnown, workloadKind, pvcCountKnown, pvcCount, replicaKnown, replicas,
	)
	debug := fmt.Sprintf("candidates=%s filtered=%s scores=[%s] filterDebug=[%s] top=%v chosen=%s reasons=%v",
		strings.Join(candidates, ","), filteredStr, scoresStr, filterDebugStr, top, chosen, scoreReasons[chosen],
	)

	return chosen, reason, debug
}

// normalizeTier는 Gluesys 4-tier 표준(L1/L2/L3/S3)으로 입력값을 정규화한다.
//
// 인식 가능한 입력 (대소문자 무관, 공백 trim):
//   - L1, burst, cache         → ("L1", "storage-l1")
//   - L2, performance          → ("L2", "storage-l2")
//   - L3, capacity             → ("L3", "storage-l3")
//   - S3, archive              → ("S3", "storage-s3")
//
// Parameters:
//   - rawTier: 외부에서 들어온 tier 문자열 (PVC annotation, label 등).
//
// Returns:
//   - string: 표준 tier 이름(L1/L2/L3/S3). 인식 실패 시 빈 문자열.
//   - string: 매핑된 StorageClass 이름. 인식 실패 시 빈 문자열.
func normalizeTier(rawTier string) (string, string) {
	switch strings.ToLower(strings.TrimSpace(rawTier)) {
	case "l1", "burst", "cache":
		return tierL1, storageClassL1
	case "l2", "performance":
		return tierL2, storageClassL2
	case "l3", "capacity":
		return tierL3, storageClassL3
	case "s3", "archive":
		return tierS3, storageClassS3
	default:
		return "", ""
	}
}

// isFinalTierValue는 입력 값이 이미 표준 L1/L2/L3/S3 인지 검사한다.
// L1/L2/L3/S3 가 아닌 경우(legacy burst/cache/performance/capacity/archive 포함) false를 반환한다.
func isFinalTierValue(raw string) bool {
	switch strings.TrimSpace(raw) {
	case tierL1, tierL2, tierL3, tierS3:
		return true
	default:
		return false
	}
}

// isFinalStorageClassValue는 입력 값이 이미 표준 storage-l1/l2/l3/s3 SC 이름인지 검사한다.
func isFinalStorageClassValue(raw string) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case storageClassL1, storageClassL2, storageClassL3, storageClassS3:
		return true
	default:
		return false
	}
}

// isLegacyStorageClassValue는 입력 값이 burst/performance/capacity/archive 체계의 legacy SC 이름인지 검사한다.
func isLegacyStorageClassValue(raw string) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "storage-burst", "storage-cache", "storage-performance", "storage-capacity", "storage-archive":
		return true
	default:
		return false
	}
}

// =============================================================================
// 3단계: Hard Rule + AHP Score Rule 기반 tier 선정
//
// 결정 우선순위:
//  1. createPVCPatch 가 먼저 existingFinalTierFromPVC(보존) 를 확인.
//  2. hardRuleSelect — tier-hint / archive-계열 data-role / cache+repeated|ultra-low.
//     맞으면 그 tier 그대로 확정한다(점수 로직 우회).
//  3. scoreRuleSelect — AHP 기반 100점 스케일 가중치로 L1/L2/L3/S3 점수를 합산하고
//     최고점을 선택한다(동점 시 L2 > L3 > L1 > S3 순으로 폴백).
//  4. 위 어느 단계도 입력이 없으면 default L2 로 폴백한다.
//
// 점수 설계 메모(쌍대비교 기반 정책 가중치 — 실측 성능 수치 아님):
//   - data-role(50)   : 데이터 목적/생명주기 자체. 가장 강한 시그널.
//   - workload-type(25): 실행 단계만 표현. data-role 절반.
//   - access-pattern, latency(15~30): I/O 특성 보정. 중간 가중치.
//   - io-pattern(10~20): I/O 패턴 보정.
//   - priority(5~10)  : data-role 결과를 뒤집지 않도록 낮게 제한.
//   - weight(5)       : 사용자 가중치. 보조적 보정만 허용.
// =============================================================================

// tierScores는 L1/L2/L3/S3 네 tier 의 AHP 점수를 보관한다.
type tierScores struct {
	L1, L2, L3, S3 int
}

// scoreContribution은 한 카테고리(예: data-role=cache)가 각 tier 에 더한 점수.
// tier-reason annotation 빌드 시 "key=value(+N)" 형식으로 선정 tier 의 점수만 노출한다.
type scoreContribution struct {
	Key   string
	Value string
	// pts[0]=L1, pts[1]=L2, pts[2]=L3, pts[3]=S3
	pts [4]int
}

// hardRuleSelect는 3단계 Hard Rule 을 평가해 tier 가 확정되면 (tier, reason, true) 를
// 반환한다. 입력이 충분치 않으면 ("", "", false) 를 반환해 호출자가 score rule 로
// 폴백하게 한다.
//
// Hard Rule 우선순위:
//  1. tier-hint == L1/L2/L3/S3 → 그대로 사용
//  2. tier-hint == burst/cache/performance/capacity/archive → normalize 후 사용
//  3. data-role ∈ {archive, backup, result-backup, old-log} → S3 강제
//  4. data-role ∈ {cache, metadata-cache, repeated-access, shard-index-cache}
//     이면서 access-pattern=repeated 또는 latency=ultra-low → L1 강제
//
// Parameters:
//   - pvc: 대상 PVC.
//
// Returns:
//   - string: 확정된 tier (L1/L2/L3/S3). 미확정 시 빈 문자열.
//   - string: 사람이 읽을 수 있는 hard rule 매칭 사유.
//   - bool:   hard rule 매칭 여부.
func hardRuleSelect(pvc *corev1.PersistentVolumeClaim) (string, string, bool) {
	if pvc == nil {
		return "", "", false
	}
	read := func(keys ...string) string {
		return strings.TrimSpace(getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, keys...))
	}

	// 1) tier-hint 우선
	if raw := read(tierHintAnnotation); raw != "" {
		if isFinalTierValue(raw) {
			return raw, fmt.Sprintf("tier-hint=%s (final)", raw), true
		}
		if normalized, _ := normalizeTier(raw); normalized != "" {
			return normalized, fmt.Sprintf("tier-hint=%s -> %s (legacy normalize)", raw, normalized), true
		}
	}

	// 2) data-role archive-계열 → S3 강제
	role := strings.ToLower(read(dataRoleAnnotation))
	switch role {
	case "archive", "backup", "result-backup", "old-log":
		return tierS3, fmt.Sprintf("data-role=%s -> S3 (hard)", role), true
	}

	// 3) data-role cache-계열 + (access=repeated OR latency=ultra-low) → L1 강제
	switch role {
	case "cache", "metadata-cache", "repeated-access", "shard-index-cache":
		ap := strings.ToLower(read(accessPatternAnnotation))
		lat := strings.ToLower(read(latencyAnnotation))
		if ap == "repeated" || lat == "ultra-low" {
			return tierL1, fmt.Sprintf("data-role=%s + (access-pattern=%s|latency=%s) -> L1 (hard)", role, ap, lat), true
		}
	}

	return "", "", false
}

// scoreRuleSelect는 AHP 가중치 표(정책 가중치)에 따라 L1/L2/L3/S3 점수를 합산하고
// 최고점 tier 를 반환한다. 동점은 L2 > L3 > L1 > S3 순으로 끊는다.
//
// 입력이 하나도 없으면 (tier=L2, scores=모두0, hasInput=false) 를 반환해
// 호출자가 legacy score 또는 default-l2 폴백으로 갈 수 있게 한다.
//
// Parameters:
//   - pvc: 대상 PVC.
//
// Returns:
//   - string:              선정된 tier (L1/L2/L3/S3).
//   - []scoreContribution: 각 카테고리별 점수 contribution(tier-reason 빌드용).
//   - tierScores:          최종 tier 별 합산 점수.
//   - bool:                AHP 입력이 하나라도 있었는지 여부.
func scoreRuleSelect(pvc *corev1.PersistentVolumeClaim) (string, []scoreContribution, tierScores, bool) {
	var s tierScores
	if pvc == nil {
		return tierL2, nil, s, false
	}
	read := func(keys ...string) string {
		return strings.TrimSpace(getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, keys...))
	}

	var contribs []scoreContribution
	hasInput := false

	add := func(key, value string, l1, l2, l3, s3 int) {
		s.L1 += l1
		s.L2 += l2
		s.L3 += l3
		s.S3 += s3
		contribs = append(contribs, scoreContribution{Key: key, Value: value, pts: [4]int{l1, l2, l3, s3}})
	}

	// 1) data-role (가장 강한 시그널, 50)
	if raw := read(dataRoleAnnotation); raw != "" {
		hasInput = true
		switch strings.ToLower(raw) {
		case "cache", "metadata-cache", "repeated-access", "shard-index-cache":
			add("data-role", raw, 50, 0, 0, 0)
		case "preprocessing-input", "training-input", "inference-input", "hot-data", "input":
			add("data-role", raw, 0, 50, 0, 0)
		case "raw-dataset", "intermediate", "warm-data", "cold-data":
			add("data-role", raw, 0, 0, 50, 0)
		case "backup", "archive", "result-backup", "old-log":
			add("data-role", raw, 0, 0, 0, 50)
		}
	}

	// 2) workload-type (실행 단계 시그널, 25)
	if raw := read(workloadTypeHintAnnotation); raw != "" {
		hasInput = true
		switch strings.ToLower(raw) {
		case "preprocessing", "training", "inference":
			add("workload-type", raw, 0, 25, 0, 0)
		case "dataset-ingest":
			add("workload-type", raw, 0, 0, 25, 0)
		case "archive":
			add("workload-type", raw, 0, 0, 0, 25)
		}
	}

	// 3) access-pattern (I/O 특성 보정, 15~30)
	if raw := read(accessPatternAnnotation); raw != "" {
		hasInput = true
		switch strings.ToLower(raw) {
		case "repeated":
			add("access-pattern", raw, 30, 0, 0, 0)
		case "frequent":
			add("access-pattern", raw, 0, 20, 0, 0)
		case "occasional":
			add("access-pattern", raw, 0, 0, 15, 0)
		case "rare":
			add("access-pattern", raw, 0, 0, 0, 20)
		}
	}

	// 4) latency (I/O 특성 보정, 15~30)
	if raw := read(latencyAnnotation); raw != "" {
		switch strings.ToLower(raw) {
		case "ultra-low":
			hasInput = true
			add("latency", raw, 30, 0, 0, 0)
		case "low":
			hasInput = true
			add("latency", raw, 0, 25, 0, 0)
		case "normal":
			hasInput = true
			add("latency", raw, 0, 0, 15, 0)
		case "high-ok":
			hasInput = true
			add("latency", raw, 0, 0, 0, 20)
		// 그 외(예: "0ms" 같은 수치/legacy)는 점수 가산 없이 무시한다.
		}
	}

	// 5) io-pattern (10~20)
	if raw := read(ioPatternAnnotation); raw != "" {
		hasInput = true
		switch strings.ToLower(raw) {
		case "small-random-read", "metadata-read":
			add("io-pattern", raw, 20, 0, 0, 0)
		case "large-read", "large-sequential-read":
			add("io-pattern", raw, 0, 15, 10, 0)
		case "large-write":
			add("io-pattern", raw, 0, 0, 15, 10)
		}
	}

	// 6) priority (보정값, 5~10; data-role 결과를 단독으로 뒤집을 만큼 크지 않다)
	if raw := read(priorityAnnotation); raw != "" {
		hasInput = true
		switch strings.ToLower(raw) {
		case "high":
			// L1 단독 승격 방지를 위해 L2 가중을 더 크게 둔다.
			add("priority", raw, 5, 10, 0, 0)
		case "medium":
			add("priority", raw, 0, 5, 5, 0)
		case "low":
			add("priority", raw, 0, 0, 5, 10)
		}
	}

	// 7) weight (사용자 가중치, 5; archive/backup 을 L2/L1로 끌어올리지 않음)
	if raw := read(weightAnnotation); raw != "" {
		if w, err := strconv.ParseFloat(raw, 64); err == nil {
			hasInput = true
			switch {
			case w >= 1.5:
				add("weight", raw, 5, 5, 0, 0)
			case w >= 1.0:
				add("weight", raw, 0, 5, 0, 0)
			default:
				add("weight", raw, 0, 0, 5, 0)
			}
		}
	}

	if !hasInput {
		return tierL2, nil, s, false
	}

	tier := pickTierByScore(s)
	return tier, contribs, s, true
}

// pickTierByScore는 tierScores 중 최고점 tier 를 반환한다.
// 동점 또는 모두 0 인 경우 L2 > L3 > L1 > S3 순으로 폴백한다.
// (요구사항: L1 단독 승격 금지 — weight=2.0 단독, priority=high 단독 등에서 L1을 피하기 위함)
func pickTierByScore(s tierScores) string {
	type tp struct {
		tier string
		pts  int
		ord  int // tie-break 우선순위(작을수록 우선): L2=0, L3=1, L1=2, S3=3
	}
	cands := []tp{
		{tierL2, s.L2, 0},
		{tierL3, s.L3, 1},
		{tierL1, s.L1, 2},
		{tierS3, s.S3, 3},
	}
	best := cands[0]
	for _, c := range cands[1:] {
		if c.pts > best.pts {
			best = c
			continue
		}
		if c.pts == best.pts && c.ord < best.ord {
			best = c
		}
	}
	return best.tier
}

// buildTierReason은 selection-path/scores/주요 contribution 을 단일 문자열로 직렬화해
// ai-storage/tier-reason annotation 에 박을 사람이 읽을 수 있는 사유를 만든다.
//
// 형식 예시:
//
//	selection-path=score-rule; selected=L2; storage-class=storage-l2;
//	scores={L1:10,L2:130,L3:10,S3:0};
//	reason=data-role=preprocessing-input(+50), workload-type=preprocessing(+25), latency=low(+25), priority=high(+10)
func buildTierReason(path, tier, className string, scores tierScores, contribs []scoreContribution, hardReason string) string {
	tierIdx := map[string]int{tierL1: 0, tierL2: 1, tierL3: 2, tierS3: 3}
	idx, ok := tierIdx[tier]
	parts := make([]string, 0, len(contribs))
	if ok && len(contribs) > 0 {
		for _, c := range contribs {
			if c.pts[idx] > 0 {
				parts = append(parts, fmt.Sprintf("%s=%s(+%d)", c.Key, c.Value, c.pts[idx]))
			}
		}
	}
	reasonBody := ""
	switch {
	case hardReason != "":
		reasonBody = hardReason
	case len(parts) > 0:
		reasonBody = strings.Join(parts, ", ")
	default:
		reasonBody = "no-contribution"
	}
	return fmt.Sprintf("selection-path=%s; selected=%s; storage-class=%s; scores={L1:%d,L2:%d,L3:%d,S3:%d}; reason=%s",
		path, tier, className, scores.L1, scores.L2, scores.L3, scores.S3, reasonBody)
}

// hasScoreSignals는 PVC labels/annotations 에 기존 점수 로직(selectStorageClass)이
// 의미 있게 처리할 수 있는 입력이 하나라도 있는지 확인한다.
//
// 다음 키 중 하나라도 값이 있으면 true 를 반환한다.
//   - storage-tier (explicit tier override)
//   - workload.keti.io/type, workload.keti.io/stage, stage, ai-storage/stage
//   - workload.keti.io/framework, framework, ai-storage/framework
//   - gpuCount, gpu-count, ai-storage/gpu-count
//   - workload.keti.io/kind, workload.keti.io/mount-path, workload.keti.io/read-only
//   - workload.keti.io/pvc-count, workload.keti.io/replica-count
//
// rule 기반 결정이 실패(hasRuleInput=false) 했을 때, 이 함수가 true이면 호출자는
// 기존 점수 로직(selectStorageClass)을 호출해 보조 결정을 시도한다.
func hasScoreSignals(pvc *corev1.PersistentVolumeClaim) bool {
	if pvc == nil {
		return false
	}
	keys := []string{
		storageTierAnnotation,
		workloadTypeAnnotation, workloadTypeLabel,
		metadataStageLabel, metadataStageAnnotation, workloadStageLabel,
		workloadFrameworkLabel, metadataFrameworkLabel, metadataFrameworkAnnotation,
		metadataGPUCountLabel, metadataGPUCountLabelAlt, metadataGPUCountAnnotation,
		workloadKindLabel, mountPathLabel, readOnlyLabel,
		pvcCountLabel, replicaCountLabel,
	}
	return strings.TrimSpace(getMetadataValueFromMaps(pvc.Labels, pvc.Annotations, keys...)) != ""
}

// existingFinalTierFromPVC는 PVC에 이미 명확한 tier 결정(L1~S3)이 박혀 있는지 확인한다.
//
// "이미 결정된" 의 정의는 이전 admission 사이클에서 결과로 박힌 값 또는 사용자가
// 직접 지정한 storageClassName 이다. tier-hint 는 hard-rule 의 입력이므로 여기서
// 처리하지 않는다(별도 hardRuleSelect 가 다룬다).
//
// 검사 우선순위:
//  1. PVC.annotations["ai-storage/selected-tier"]              (이전 admission 결과)
//  2. PVC.annotations["ai-storage/selected-storage-class"]     (이전 admission 결과)
//  3. PVC.labels["ai-storage-selected-tier"]                   (이전 admission 결과)
//  4. PVC.spec.storageClassName                                 (사용자 명시)
//
// 발견된 값이 L1~S3 (또는 normalize 가능한 legacy 값)이면 normalize된 표준 tier(L1~S3)를 반환한다.
// 어떤 항목에도 유효한 값이 없으면 빈 문자열을 반환하여 hard/score 로직으로 폴백되게 한다.
func existingFinalTierFromPVC(pvc *corev1.PersistentVolumeClaim) string {
	if pvc == nil {
		return ""
	}

	candidates := make([]string, 0, 4)
	if pvc.Annotations != nil {
		candidates = append(candidates,
			pvc.Annotations[selectedTierAnnotation],
			pvc.Annotations[selectedStorageClassAnnotation],
		)
	}
	if pvc.Labels != nil {
		candidates = append(candidates, pvc.Labels[selectedTierLabel])
	}
	if pvc.Spec.StorageClassName != nil {
		candidates = append(candidates, *pvc.Spec.StorageClassName)
	}

	for _, raw := range candidates {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if normalized, _ := normalizeTier(raw); normalized != "" {
			return normalized
		}
		if isFinalStorageClassValue(raw) || isLegacyStorageClassValue(raw) {
			return storageClassToTier(raw)
		}
	}
	return ""
}

func autoSelectTierByMetadata(pvc *corev1.PersistentVolumeClaim) (string, string) {
	stage := strings.ToLower(strings.TrimSpace(getMetadataValue(pvc, metadataStageLabel, metadataStageAnnotation, workloadStageLabel)))
	gpuCount := parseGPUCount(getMetadataValue(pvc, metadataGPUCountLabel, metadataGPUCountLabelAlt, metadataGPUCountAnnotation))

	if stage == "train" && gpuCount > 0 {
		return tierL2, storageClassL2
	}
	if stage == "preprocess" {
		return tierL1, storageClassL1
	}
	if stage == "inference" {
		return tierL3, storageClassL3
	}
	return tierS3, storageClassS3
}

func getMetadataValue(pvc *corev1.PersistentVolumeClaim, keys ...string) string {
	for _, key := range keys {
		if pvc.Annotations != nil {
			if v, ok := pvc.Annotations[key]; ok && strings.TrimSpace(v) != "" {
				return v
			}
		}
		if pvc.Labels != nil {
			if v, ok := pvc.Labels[key]; ok && strings.TrimSpace(v) != "" {
				return v
			}
		}
	}
	return ""
}

func parseGPUCount(raw string) int {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// =============================================================================
// hasSidecar: insight-trace 컨테이너가 이미 있는지 확인
//
// 사용자가 YAML에 직접 insight-trace를 넣었거나,
// 이전에 웹훅이 이미 주입한 경우 중복 방지.
//
// 컨테이너 이름 "insight-trace"로 매칭.
// =============================================================================
func (h *MutationHandler) hasSidecar(pod *corev1.Pod) bool {
	for _, c := range pod.Spec.Containers {
		if c.Name == "insight-trace" {
			return true
		}
	}
	return false
}

// mainContainerAnnotationKeys는 Pod annotation에서 메인 컨테이너 이름을 결정할 때
// 우선 탐색하는 키 목록이다. 슬라이스 순서가 그대로 우선순위가 된다.
var mainContainerAnnotationKeys = []string{
	// WHY: AI Storage demo 표준 키를 최우선 인식한다.
	"insight-trace.keti.io/main-container",
	"mlops.keti.io/main-container",
	"workload.keti.io/main-container",
	"ai-storage/main-container",
}

// sidecarContainerNames는 메인 컨테이너 후보에서 제외하는 사이드카 이름 집합.
var sidecarContainerNames = map[string]struct{}{
	"insight-trace": {},
	"istio-proxy":   {},
}

// defaultMainContainerName은 annotation도 없고 워크로드 컨테이너도 없는 비정상 케이스에서 사용하는
// 최후 fallback 값. 이 값을 직접 가정하는 워크로드가 없도록 운영 정책상 권장하지 않지만,
// CONTAINER_NAME 환경변수를 빈 문자열로 두지 않기 위한 안전망이다.
const defaultMainContainerName = "main"

// =============================================================================
// buildSidecarContainer: Insight-Trace 사이드카 컨테이너 정의 생성
//
// 이 함수가 반환하는 corev1.Container가 Pod에 주입됨.
//
// 환경변수 설명:
//
//	POD_NAME        : 현재 Pod 이름 (fieldRef로 자동 주입)
//	POD_NAMESPACE   : 현재 네임스페이스
//	NODE_NAME       : Pod가 배치된 노드
//	CONTAINER_NAME  : 모니터링 대상 메인 컨테이너 이름
//	                  → 우선순위 (resolveMainContainerName 참조):
//	                    1) Pod annotation 키 순서대로 검사:
//	                       mlops.keti.io/main-container,
//	                       workload.keti.io/main-container,
//	                       ai-storage/main-container
//	                    2) insight-trace/istio-proxy 등을 제외한 첫 번째 컨테이너 이름
//	                    3) 그래도 못 찾으면 "main" (사용자 YAML이 main 이름을 강제하지 않도록
//	                       어디까지나 fallback. 정상 경로에서는 사용되지 않음)
//	APOLLO_ENDPOINT : APOLLO gRPC 서버 주소
//	                  → Insight-Trace가 분석 결과를 전송하는 대상
//	METRICS_INTERVAL_SECONDS  : 메트릭 수집 주기 (5초)
//	ANALYSIS_INTERVAL_SECONDS : I/O 패턴 분석 주기 (10초)
//	REPORT_INTERVAL_SECONDS   : APOLLO 전송 주기 (15초)
//
// 리소스 제한:
//
//	requests: cpu 20m, memory 32Mi → 매우 가벼운 사이드카
//	limits:   cpu 100m, memory 64Mi → 최대 사용량 제한
//	→ 메인 워크로드에 거의 영향 없음
//
// =============================================================================
func (h *MutationHandler) buildSidecarContainer(pod *corev1.Pod) corev1.Container {
	mainContainerName := h.resolveMainContainerName(pod)
	return corev1.Container{
		Name:  "insight-trace",
		Image: h.config.SidecarImage,
		// WHY: 사이드카 이미지는 클러스터 노드에 import 된 로컬 빌드일 수 있어
		//      ImagePullPolicy=Always 면 외부 레지스트리에 없는 태그에서 BackOff 한다.
		//      로컬 우선 사용을 보장한다.
		ImagePullPolicy: corev1.PullIfNotPresent,
		Env: []corev1.EnvVar{
			// ─────────────────────────────────────────────────
			// Downward API로 Pod 메타데이터를 환경변수로 주입
			// K8s가 Pod 생성 시 자동으로 값을 채워줌
			// ─────────────────────────────────────────────────
			{
				Name: "POD_NAME",
				ValueFrom: &corev1.EnvVarSource{
					FieldRef: &corev1.ObjectFieldSelector{
						FieldPath: "metadata.name",
					},
				},
			},
			{
				Name: "POD_NAMESPACE",
				ValueFrom: &corev1.EnvVarSource{
					FieldRef: &corev1.ObjectFieldSelector{
						FieldPath: "metadata.namespace",
					},
				},
			},
			{
				Name: "NODE_NAME",
				ValueFrom: &corev1.EnvVarSource{
					FieldRef: &corev1.ObjectFieldSelector{
						FieldPath: "spec.nodeName",
					},
				},
			},
			// ─────────────────────────────────────────────────
			// 사이드카 설정값 (정적 값)
			// ─────────────────────────────────────────────────
			{
				Name:  "CONTAINER_NAME",
				Value: mainContainerName,
			},
			{
				Name:  "APOLLO_ENDPOINT",
				Value: h.config.ApolloEndpoint,
			},
			{
				Name:  "METRICS_INTERVAL_SECONDS",
				Value: "5",
			},
			{
				Name:  "ANALYSIS_INTERVAL_SECONDS",
				Value: "10",
			},
			{
				Name:  "REPORT_INTERVAL_SECONDS",
				Value: "15",
			},
		},
		Resources: corev1.ResourceRequirements{
			Requests: corev1.ResourceList{
				corev1.ResourceCPU:    mustParseQuantity("20m"),
				corev1.ResourceMemory: mustParseQuantity("32Mi"),
			},
			Limits: corev1.ResourceList{
				corev1.ResourceCPU:    mustParseQuantity("100m"),
				corev1.ResourceMemory: mustParseQuantity("64Mi"),
			},
		},
	}
}

// resolveMainContainerName은 메인 컨테이너 이름을 우선순위 규칙으로 결정한다.
//
// 우선순위:
//  1. mainContainerAnnotationKeys에 등록된 Pod annotation을 순서대로 검사하여 처음으로
//     발견한 비어 있지 않은 값을 사용한다.
//  2. sidecarContainerNames에 포함되지 않은 첫 번째 컨테이너 이름을 사용한다.
//  3. 그래도 결정되지 않으면 defaultMainContainerName("main")을 fallback으로 사용한다.
//
// 정상 워크로드(컨테이너가 1개 이상 존재)에서는 1단계 또는 2단계에서 반드시 결정되며,
// 3단계는 컨테이너가 sidecar만 들어 있는 비정상 케이스의 안전망이다. 즉 사용자가
// 워크로드 YAML에서 컨테이너 이름을 "main"으로 강제할 필요가 없다.
func (h *MutationHandler) resolveMainContainerName(pod *corev1.Pod) string {
	if pod == nil {
		return defaultMainContainerName
	}

	if pod.Annotations != nil {
		for _, key := range mainContainerAnnotationKeys {
			if v := strings.TrimSpace(pod.Annotations[key]); v != "" {
				log.Printf("[Webhook]   → mainContainer resolved by annotation %q = %q (pod=%s/%s)",
					key, v, pod.Namespace, pod.Name)
				return v
			}
		}
	}

	for _, c := range pod.Spec.Containers {
		if _, isSidecar := sidecarContainerNames[c.Name]; isSidecar {
			continue
		}
		log.Printf("[Webhook]   → mainContainer resolved by first non-sidecar container = %q (pod=%s/%s)",
			c.Name, pod.Namespace, pod.Name)
		return c.Name
	}

	log.Printf("[Webhook]   → mainContainer fallback to %q (pod=%s/%s, no annotation and no non-sidecar container)",
		defaultMainContainerName, pod.Namespace, pod.Name)
	return defaultMainContainerName
}

// =============================================================================
// sendResponse: AdmissionReview 응답 전송
//
// K8s API Server가 기대하는 응답 형식:
//
//	{
//	  "apiVersion": "admission.k8s.io/v1",
//	  "kind": "AdmissionReview",
//	  "response": {
//	    "uid": "요청과 같은 UID",
//	    "allowed": true/false,
//	    "patchType": "JSONPatch",
//	    "patch": "base64로 인코딩된 JSON Patch"
//	  }
//	}
//
// allowed=true + patch: Pod 변경 허용 + 패치 적용
// allowed=true + no patch: Pod 변경 없이 허용
// allowed=false: Pod 생성 거부 (우리는 사용하지 않음)
// =============================================================================
func (h *MutationHandler) sendResponse(w http.ResponseWriter, uid types.UID, allowed bool, message string, patch []byte) {
	response := admissionv1.AdmissionReview{
		// TypeMeta: K8s API 호환을 위해 반드시 설정
		TypeMeta: metav1.TypeMeta{
			APIVersion: "admission.k8s.io/v1",
			Kind:       "AdmissionReview",
		},
		Response: &admissionv1.AdmissionResponse{
			// UID: 요청의 UID를 그대로 반환해야 함 (매칭용)
			UID:     uid,
			Allowed: allowed,
			Result: &metav1.Status{
				Message: message,
			},
		},
	}

	// 패치가 있으면 응답에 포함
	if patch != nil {
		// PatchType: 패치 형식 지정
		// JSONPatch = RFC 6902 (op/path/value 형식)
		// K8s는 JSONPatch와 MergePatch를 지원하지만
		// JSONPatch가 더 세밀한 제어 가능
		patchType := admissionv1.PatchTypeJSONPatch
		response.Response.PatchType = &patchType
		response.Response.Patch = patch
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("[Webhook] Failed to encode response: %v", err)
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

// =============================================================================
// mustParseQuantity: K8s 리소스 수량 문자열을 파싱하는 헬퍼
//
// "20m"  → 20 millicores (0.02 CPU)
// "32Mi" → 32 MiB 메모리
// "1"    → 1 CPU core
// "2Gi"  → 2 GiB 메모리
//
// 잘못된 형식이면 panic (빌드 타임에 잡히는 상수값이므로 안전)
// =============================================================================
func mustParseQuantity(s string) resource.Quantity {
	q, err := resource.ParseQuantity(s)
	if err != nil {
		panic(fmt.Sprintf("invalid quantity: %s", s))
	}
	return q
}
