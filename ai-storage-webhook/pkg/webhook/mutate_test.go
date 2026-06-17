package webhook

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
)

// =============================================================================
// 테스트 헬퍼: 기본 WebhookConfig 생성
// =============================================================================
func testConfig() WebhookConfig {
	return WebhookConfig{
		SidecarImage:              "ketidevit2/insight-trace:latest",
		ApolloEndpoint:            "apollo-policy-server.keti.svc.cluster.local:50051",
		SchedulerName:             "ai-storage-scheduler",
		PlanAPIBaseURL:            "",
		ReplaceableStorageClasses: []string{"nfs-client"},
	}
}

// =============================================================================
// 테스트 헬퍼: Pod → AdmissionReview HTTP 요청 생성
// =============================================================================
func createAdmissionRequest(t *testing.T, pod *corev1.Pod) *http.Request {
	t.Helper()

	podJSON, err := json.Marshal(pod)
	if err != nil {
		t.Fatalf("Failed to marshal pod: %v", err)
	}

	review := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "admission.k8s.io/v1",
			Kind:       "AdmissionReview",
		},
		Request: &admissionv1.AdmissionRequest{
			UID:       types.UID("test-uid-12345"),
			Namespace: "kubeflow-user-example-com",
			Name:      pod.Name,
			Kind: metav1.GroupVersionKind{
				Group:   "",
				Version: "v1",
				Kind:    "Pod",
			},
			Object: runtime.RawExtension{
				Raw: podJSON,
			},
		},
	}

	body, err := json.Marshal(review)
	if err != nil {
		t.Fatalf("Failed to marshal review: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/mutate", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	return req
}

func createPVCAdmissionRequest(t *testing.T, pvc *corev1.PersistentVolumeClaim) *http.Request {
	t.Helper()

	pvcJSON, err := json.Marshal(pvc)
	if err != nil {
		t.Fatalf("Failed to marshal pvc: %v", err)
	}

	review := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "admission.k8s.io/v1",
			Kind:       "AdmissionReview",
		},
		Request: &admissionv1.AdmissionRequest{
			UID:       types.UID("test-pvc-uid-12345"),
			Namespace: "kubeflow-user-example-com",
			Name:      pvc.Name,
			Kind: metav1.GroupVersionKind{
				Group:   "",
				Version: "v1",
				Kind:    "PersistentVolumeClaim",
			},
			Object: runtime.RawExtension{
				Raw: pvcJSON,
			},
		},
	}

	body, err := json.Marshal(review)
	if err != nil {
		t.Fatalf("Failed to marshal review: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/mutate", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	return req
}

// =============================================================================
// 테스트 헬퍼: HTTP 응답에서 패치 추출
// =============================================================================
func extractPatches(t *testing.T, w *httptest.ResponseRecorder) ([]patchOperation, bool) {
	t.Helper()

	var review admissionv1.AdmissionReview
	if err := json.Unmarshal(w.Body.Bytes(), &review); err != nil {
		t.Fatalf("Failed to unmarshal response: %v", err)
	}

	if review.Response == nil {
		t.Fatal("Response is nil")
	}

	allowed := review.Response.Allowed

	if review.Response.Patch == nil {
		return nil, allowed
	}

	var patches []patchOperation
	if err := json.Unmarshal(review.Response.Patch, &patches); err != nil {
		t.Fatalf("Failed to unmarshal patches: %v", err)
	}

	return patches, allowed
}

// =============================================================================
// 테스트 헬퍼: 특정 패치가 있는지 확인
// =============================================================================
func hasPatchForPath(patches []patchOperation, path string) bool {
	for _, p := range patches {
		if p.Path == path {
			return true
		}
	}
	return false
}

func getPatchForPath(patches []patchOperation, path string) *patchOperation {
	for _, p := range patches {
		if p.Path == path {
			return &p
		}
	}
	return nil
}

// =============================================================================
// [테스트 A] 순수 Pod - 아무것도 없는 빈 Pod
//
// 기대 결과: 3개 패치 전부 적용
//  1. schedulerName → ai-storage-scheduler (replace)
//  2. shareProcessNamespace → true (add)
//  3. insight-trace 사이드카 주입 (add)
//
// =============================================================================
func TestA_EmptyPod_AllThreeInjected(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-empty-pod",
			Namespace: "kubeflow-user-example-com",
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "main", Image: "python:3.11"},
			},
		},
	}

	req := createAdmissionRequest(t, pod)
	w := httptest.NewRecorder()
	handler.Handle(w, req)

	patches, allowed := extractPatches(t, w)

	// 허용되어야 함
	if !allowed {
		t.Fatal("[A] Pod should be allowed")
	}

	// 기존 Pod 주입 3개 + KETI metadata 2개(labels/annotations)
	if len(patches) != 5 {
		t.Fatalf("[A] Expected 5 patches, got %d: %+v", len(patches), patches)
	}

	// schedulerName 패치
	p := getPatchForPath(patches, "/spec/schedulerName")
	if p == nil {
		t.Fatal("[A] Missing schedulerName patch")
	}
	if p.Op != "replace" {
		t.Errorf("[A] schedulerName op should be 'replace', got '%s'", p.Op)
	}
	if p.Value != "ai-storage-scheduler" {
		t.Errorf("[A] schedulerName value should be 'ai-storage-scheduler', got '%v'", p.Value)
	}

	// shareProcessNamespace 패치
	p = getPatchForPath(patches, "/spec/shareProcessNamespace")
	if p == nil {
		t.Fatal("[A] Missing shareProcessNamespace patch")
	}
	if p.Op != "add" {
		t.Errorf("[A] shareProcessNamespace op should be 'add', got '%s'", p.Op)
	}

	// sidecar 패치
	p = getPatchForPath(patches, "/spec/containers/-")
	if p == nil {
		t.Fatal("[A] Missing sidecar patch")
	}
	if p.Op != "add" {
		t.Errorf("[A] sidecar op should be 'add', got '%s'", p.Op)
	}

	t.Log("[A] PASS: 순수 Pod → 필수 3개 주입 + KETI metadata 주입됨")
}

// =============================================================================
// [테스트 B] schedulerName: default-scheduler가 설정된 Pod
//
// 기대 결과: schedulerName이 ai-storage-scheduler로 교체
// =============================================================================
func TestB_DefaultScheduler_Replaced(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-default-scheduler",
		},
		Spec: corev1.PodSpec{
			SchedulerName: "default-scheduler",
			Containers: []corev1.Container{
				{Name: "main", Image: "python:3.11"},
			},
		},
	}

	patches := handler.createPatch(pod)

	p := getPatchForPath(patches, "/spec/schedulerName")
	if p == nil {
		t.Fatal("[B] Missing schedulerName patch")
	}
	if p.Op != "replace" {
		t.Errorf("[B] Expected 'replace', got '%s'", p.Op)
	}
	if p.Value != "ai-storage-scheduler" {
		t.Errorf("[B] Expected 'ai-storage-scheduler', got '%v'", p.Value)
	}

	t.Log("[B] PASS: default-scheduler → ai-storage-scheduler 교체됨")
}

// =============================================================================
// [테스트 C] schedulerName: ai-storage-scheduler가 이미 설정된 Pod
//
// 기대 결과: schedulerName 패치 없음 (이미 올바른 값)
// =============================================================================
func TestC_CorrectScheduler_NoChange(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-correct-scheduler",
		},
		Spec: corev1.PodSpec{
			SchedulerName: "ai-storage-scheduler",
			Containers: []corev1.Container{
				{Name: "main", Image: "python:3.11"},
			},
		},
	}

	patches := handler.createPatch(pod)

	if hasPatchForPath(patches, "/spec/schedulerName") {
		t.Fatal("[C] schedulerName should NOT be patched (already correct)")
	}

	t.Log("[C] PASS: 이미 올바른 schedulerName → 패치 없음")
}

// =============================================================================
// [테스트 D] insight-trace 사이드카가 이미 있는 Pod
//
// 기대 결과: 사이드카 중복 주입 안됨
// =============================================================================
func TestD_ExistingSidecar_NoDuplicate(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-existing-sidecar",
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "main", Image: "python:3.11"},
				{Name: "insight-trace", Image: "ketidevit2/insight-trace:latest"},
			},
		},
	}

	patches := handler.createPatch(pod)

	if hasPatchForPath(patches, "/spec/containers/-") {
		t.Fatal("[D] Sidecar should NOT be injected (already exists)")
	}

	// schedulerName, shareProcessNamespace는 여전히 패치됨
	if !hasPatchForPath(patches, "/spec/schedulerName") {
		t.Error("[D] schedulerName should still be patched")
	}
	if !hasPatchForPath(patches, "/spec/shareProcessNamespace") {
		t.Error("[D] shareProcessNamespace should still be patched")
	}

	// 기존 패치 2개(schedulerName, shareProcessNamespace) + KETI metadata 2개(labels/annotations)
	if len(patches) != 4 {
		t.Errorf("[D] Expected 4 patches (no sidecar), got %d", len(patches))
	}

	t.Log("[D] PASS: 사이드카 이미 존재 → 중복 주입 안됨, 나머지 2개만 패치")
}

// =============================================================================
// [테스트 E] keti-ai-storage-injection=disabled label이 있는 Pod
//
// 기대 결과: 전체 스킵 (패치 0개, allowed=true)
//
// 이 테스트는 Handle() 전체를 테스트해야 함 (createPatch 이전에 체크)
// =============================================================================
func TestE_DisabledLabel_SkipAll(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-disabled",
			Labels: map[string]string{
				"keti-ai-storage-injection": "disabled",
			},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "main", Image: "python:3.11"},
			},
		},
	}

	req := createAdmissionRequest(t, pod)
	w := httptest.NewRecorder()
	handler.Handle(w, req)

	patches, allowed := extractPatches(t, w)

	if !allowed {
		t.Fatal("[E] Pod should be allowed even when disabled")
	}
	if len(patches) != 0 {
		t.Fatalf("[E] Expected 0 patches for disabled pod, got %d", len(patches))
	}

	t.Log("[E] PASS: disabled label → 패치 0개, Pod 허용")
}

// =============================================================================
// [테스트 F] shareProcessNamespace: true가 이미 설정된 Pod
//
// 기대 결과: shareProcessNamespace 패치 없음
// =============================================================================
func TestF_ShareProcessAlreadyTrue_NoChange(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	shareProcess := true
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-share-process-true",
		},
		Spec: corev1.PodSpec{
			ShareProcessNamespace: &shareProcess,
			Containers: []corev1.Container{
				{Name: "main", Image: "python:3.11"},
			},
		},
	}

	patches := handler.createPatch(pod)

	if hasPatchForPath(patches, "/spec/shareProcessNamespace") {
		t.Fatal("[F] shareProcessNamespace should NOT be patched (already true)")
	}

	t.Log("[F] PASS: shareProcessNamespace 이미 true → 패치 없음")
}

// =============================================================================
// [테스트 G] shareProcessNamespace: false가 설정된 Pod
//
// 기대 결과: "replace"로 true로 변경
//
//	("add"가 아닌 "replace" — 이미 필드가 존재하므로)
//
// =============================================================================
func TestG_ShareProcessFalse_ReplacedToTrue(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	shareProcess := false
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-share-process-false",
		},
		Spec: corev1.PodSpec{
			ShareProcessNamespace: &shareProcess,
			Containers: []corev1.Container{
				{Name: "main", Image: "python:3.11"},
			},
		},
	}

	patches := handler.createPatch(pod)

	p := getPatchForPath(patches, "/spec/shareProcessNamespace")
	if p == nil {
		t.Fatal("[G] Missing shareProcessNamespace patch")
	}
	if p.Op != "replace" {
		t.Errorf("[G] Expected 'replace' (field exists as false), got '%s'", p.Op)
	}

	t.Log("[G] PASS: shareProcessNamespace false → replace로 true 변경")
}

// =============================================================================
// [테스트 H] 모든 것이 이미 올바르게 설정된 Pod
//
// 기대 결과: KETI 메타데이터 주입으로 패치 2개(labels/annotations)가 발생
//
// schedulerName: ai-storage-scheduler ✓
// shareProcessNamespace: true ✓
// insight-trace 사이드카 존재 ✓
// =============================================================================
func TestH_AllAlreadySet_ZeroPatches(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	shareProcess := true
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-all-set",
		},
		Spec: corev1.PodSpec{
			SchedulerName:         "ai-storage-scheduler",
			ShareProcessNamespace: &shareProcess,
			Containers: []corev1.Container{
				{Name: "main", Image: "python:3.11"},
				{Name: "insight-trace", Image: "ketidevit2/insight-trace:latest"},
			},
		},
	}

	patches := handler.createPatch(pod)

	if len(patches) != 2 {
		t.Fatalf("[H] Expected 2 patches (only KETI metadata), got %d: %+v", len(patches), patches)
	}

	// Handle()로도 확인 — KETI 메타데이터 패치 포함
	req := createAdmissionRequest(t, pod)
	w := httptest.NewRecorder()
	handler.Handle(w, req)

	patches2, allowed := extractPatches(t, w)
	if !allowed {
		t.Fatal("[H] Pod should be allowed")
	}
	if len(patches2) == 0 {
		t.Fatalf("[H] Handle() should return patches for KETI metadata, got 0")
	}

	t.Log("[H] PASS: 모든 것 이미 설정됨 + KETI metadata 주입")
}

// =============================================================================
// [종합 테스트] 사이드카 컨테이너 내용 검증
//
// 주입되는 insight-trace 사이드카의 env, resources가 올바른지 확인
// =============================================================================
func TestSidecarContainerContent(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pod",
			Namespace: "default",
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "workload-main"},
				{Name: "insight-trace"},
			},
		},
	}
	sidecar := handler.buildSidecarContainer(pod)

	// 이름 확인
	if sidecar.Name != "insight-trace" {
		t.Errorf("Sidecar name should be 'insight-trace', got '%s'", sidecar.Name)
	}

	// 이미지 확인
	if sidecar.Image != "ketidevit2/insight-trace:latest" {
		t.Errorf("Sidecar image mismatch: %s", sidecar.Image)
	}

	// 환경변수 확인
	expectedEnvs := map[string]bool{
		"POD_NAME":                  false, // fieldRef
		"POD_NAMESPACE":             false, // fieldRef
		"NODE_NAME":                 false, // fieldRef
		"CONTAINER_NAME":            false, // value: resolved main container
		"APOLLO_ENDPOINT":           false, // value
		"METRICS_INTERVAL_SECONDS":  false,
		"ANALYSIS_INTERVAL_SECONDS": false,
		"REPORT_INTERVAL_SECONDS":   false,
	}

	for _, env := range sidecar.Env {
		if _, ok := expectedEnvs[env.Name]; ok {
			expectedEnvs[env.Name] = true
		}
	}

	for name, found := range expectedEnvs {
		if !found {
			t.Errorf("Missing env var: %s", name)
		}
	}

	// APOLLO_ENDPOINT 값 확인
	for _, env := range sidecar.Env {
		if env.Name == "APOLLO_ENDPOINT" {
			if env.Value != "apollo-policy-server.keti.svc.cluster.local:50051" {
				t.Errorf("APOLLO_ENDPOINT mismatch: %s", env.Value)
			}
		}
		if env.Name == "CONTAINER_NAME" {
			if env.Value != "workload-main" {
				t.Errorf("CONTAINER_NAME should be workload-main, got %s", env.Value)
			}
		}
	}

	// 리소스 확인
	cpuReq := sidecar.Resources.Requests[corev1.ResourceCPU]
	if cpuReq.String() != "20m" {
		t.Errorf("CPU request should be 20m, got %s", cpuReq.String())
	}

	memLimit := sidecar.Resources.Limits[corev1.ResourceMemory]
	if memLimit.String() != "64Mi" {
		t.Errorf("Memory limit should be 64Mi, got %s", memLimit.String())
	}

	t.Log("[Sidecar] PASS: 사이드카 내용 (env, resources) 정상")
}

func TestResolveMainContainerName(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	// case 1: 표준 annotation 키 사용
	withAnnotation := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Annotations: map[string]string{
				"mlops.keti.io/main-container": "annotated-main",
			},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "first-workload"},
				{Name: "insight-trace"},
			},
		},
	}
	if got := handler.resolveMainContainerName(withAnnotation); got != "annotated-main" {
		t.Fatalf("annotation main container expected annotated-main, got %s", got)
	}

	// case 2: 대안 annotation 키(workload.keti.io/main-container)
	withWorkloadKey := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Annotations: map[string]string{
				"workload.keti.io/main-container": "workload-main-from-alt-key",
			},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "first-workload"},
				{Name: "insight-trace"},
			},
		},
	}
	if got := handler.resolveMainContainerName(withWorkloadKey); got != "workload-main-from-alt-key" {
		t.Fatalf("alt annotation key expected workload-main-from-alt-key, got %s", got)
	}

	// case 3: 또 다른 대안 annotation 키(ai-storage/main-container)
	withAIStorageKey := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Annotations: map[string]string{
				"ai-storage/main-container": "ai-storage-main",
			},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "first-workload"},
				{Name: "insight-trace"},
			},
		},
	}
	if got := handler.resolveMainContainerName(withAIStorageKey); got != "ai-storage-main" {
		t.Fatalf("ai-storage annotation key expected ai-storage-main, got %s", got)
	}

	// case 4: annotation 키 우선순위(mlops.keti.io > workload.keti.io > ai-storage/) 검증
	withMultipleKeys := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Annotations: map[string]string{
				"ai-storage/main-container":       "low-priority",
				"workload.keti.io/main-container": "mid-priority",
				"mlops.keti.io/main-container":    "high-priority",
			},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{{Name: "anything"}},
		},
	}
	if got := handler.resolveMainContainerName(withMultipleKeys); got != "high-priority" {
		t.Fatalf("annotation priority expected high-priority, got %s", got)
	}

	// case 5: annotation 없이 첫 번째 non-sidecar 컨테이너 이름 사용
	withoutAnnotation := &corev1.Pod{
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "insight-trace"},
				{Name: "istio-proxy"},
				{Name: "real-main"},
			},
		},
	}
	if got := handler.resolveMainContainerName(withoutAnnotation); got != "real-main" {
		t.Fatalf("fallback main container expected real-main, got %s", got)
	}

	// case 6: annotation 없고 워크로드 컨테이너 없을 때 "main" 으로 최종 fallback
	onlySidecars := &corev1.Pod{
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "insight-trace"},
				{Name: "istio-proxy"},
			},
		},
	}
	if got := handler.resolveMainContainerName(onlySidecars); got != "main" {
		t.Fatalf("default fallback expected main, got %s", got)
	}

	// case 7: 빈 문자열 annotation 값은 무시되고 컨테이너 fallback이 사용된다
	withEmptyAnnotation := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Annotations: map[string]string{
				"mlops.keti.io/main-container": "   ",
			},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "insight-trace"},
				{Name: "user-main"},
			},
		},
	}
	if got := handler.resolveMainContainerName(withEmptyAnnotation); got != "user-main" {
		t.Fatalf("blank annotation expected user-main fallback, got %s", got)
	}

	// case 8: nil Pod 보호
	if got := handler.resolveMainContainerName(nil); got != "main" {
		t.Fatalf("nil pod expected default main, got %s", got)
	}
}

// =============================================================================
// [종합 요약] 전체 시나리오 요약 테스트
// =============================================================================
func TestAllScenariosSummary(t *testing.T) {
	scenarios := []struct {
		name            string
		schedulerName   string
		shareProcess    *bool
		hasSidecar      bool
		disabledLabel   bool
		expectedPatches int
		description     string
	}{
		{
			name:            "A: 빈 Pod",
			schedulerName:   "",
			shareProcess:    nil,
			hasSidecar:      false,
			disabledLabel:   false,
			expectedPatches: 5,
			description:     "schedulerName + shareProcess + sidecar 전부 주입",
		},
		{
			name:            "B: default-scheduler",
			schedulerName:   "default-scheduler",
			shareProcess:    nil,
			hasSidecar:      false,
			disabledLabel:   false,
			expectedPatches: 5,
			description:     "schedulerName replace + shareProcess add + sidecar add",
		},
		{
			name:            "C: 올바른 scheduler",
			schedulerName:   "ai-storage-scheduler",
			shareProcess:    nil,
			hasSidecar:      false,
			disabledLabel:   false,
			expectedPatches: 4,
			description:     "shareProcess + sidecar만 (scheduler 스킵)",
		},
		{
			name:            "D: 사이드카 있음",
			schedulerName:   "",
			shareProcess:    nil,
			hasSidecar:      true,
			disabledLabel:   false,
			expectedPatches: 4,
			description:     "scheduler + shareProcess만 (sidecar 스킵)",
		},
		{
			name:            "F: shareProcess=true",
			schedulerName:   "",
			shareProcess:    boolPtr(true),
			hasSidecar:      false,
			disabledLabel:   false,
			expectedPatches: 4,
			description:     "scheduler + sidecar만 (shareProcess 스킵)",
		},
		{
			name:            "G: shareProcess=false",
			schedulerName:   "",
			shareProcess:    boolPtr(false),
			hasSidecar:      false,
			disabledLabel:   false,
			expectedPatches: 5,
			description:     "scheduler replace + shareProcess replace + sidecar add",
		},
		{
			name:            "H: 전부 설정됨",
			schedulerName:   "ai-storage-scheduler",
			shareProcess:    boolPtr(true),
			hasSidecar:      true,
			disabledLabel:   false,
			expectedPatches: 2,
			description:     "KETI metadata만 추가됨(패치 2개)",
		},
	}

	handler := NewMutationHandler(testConfig())

	fmt.Println("\n========================================")
	fmt.Println(" AI Storage Webhook - 시나리오 테스트 결과")
	fmt.Println("========================================")

	allPassed := true
	for _, sc := range scenarios {
		pod := &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{Name: sc.name},
			Spec: corev1.PodSpec{
				SchedulerName:         sc.schedulerName,
				ShareProcessNamespace: sc.shareProcess,
				Containers: []corev1.Container{
					{Name: "main", Image: "python:3.11"},
				},
			},
		}

		if sc.hasSidecar {
			pod.Spec.Containers = append(pod.Spec.Containers, corev1.Container{
				Name: "insight-trace", Image: "ketidevit2/insight-trace:latest",
			})
		}

		patches := handler.createPatch(pod)

		status := "PASS"
		if len(patches) != sc.expectedPatches {
			status = "FAIL"
			allPassed = false
		}

		fmt.Printf(" [%s] %-25s patches=%d (expected=%d) %s\n",
			status, sc.name, len(patches), sc.expectedPatches, sc.description)
	}

	// 테스트 E는 Handle() 레벨에서 체크 (label 확인이 Handle에 있으므로)
	fmt.Println(" ---")
	fmt.Printf(" [INFO] 테스트 E (disabled label)는 개별 테스트 참조\n")
	fmt.Println("========================================")

	if !allPassed {
		t.Fatal("Some scenarios failed")
	}
}

func boolPtr(b bool) *bool {
	return &b
}

func pvcForTierTest(name string) *corev1.PersistentVolumeClaim {
	return &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
		},
		Spec: corev1.PersistentVolumeClaimSpec{
			AccessModes: []corev1.PersistentVolumeAccessMode{
				corev1.ReadWriteOnce,
			},
		},
	}
}

func TestPVC_AnnotationOverride(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-annotation-override")
	pvc.Annotations = map[string]string{
		"storage-tier": "performance", // legacy 입력 → L2로 normalize 기대
		"stage":        "inference",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil {
		t.Fatal("storageClassName patch not found")
	}
	if p.Value != "storage-l2" {
		t.Fatalf("expected storage-l2, got %v", p.Value)
	}
}

func TestPVC_TrainGPU_Workload(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-train-gpu")
	pvc.Labels = map[string]string{
		"stage":    "train",
		"gpuCount": "1",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l2" {
		t.Fatalf("expected storage-l2 patch, got %+v", p)
	}
}

func TestPVC_Preprocess_Workload(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-preprocess")
	pvc.Annotations = map[string]string{
		"stage": "preprocess",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l1" {
		t.Fatalf("expected storage-l1 patch, got %+v", p)
	}
}

// TestPVC_DefaultFallback: 2단계 rule 기반 선정 규칙에 따라 아무 annotation 도 없을 때는
// default L2(storage-l2) 로 폴백한다(이전 단계에서는 storage-s3였음).
func TestPVC_DefaultFallback(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-default")

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l2" {
		t.Fatalf("expected storage-l2 patch (rule default), got %+v", p)
	}
	if !hasPatchForPath(patches, "/metadata/annotations/ai-storage~1selected-tier") &&
		!hasPatchForPath(patches, "/metadata/annotations") {
		t.Fatal("selected tier annotation patch not found")
	}
}

func TestPVC_StorageClassAlreadyExists_Skip(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-predefined-sc")
	existing := "user-explicit-sc"
	pvc.Spec.StorageClassName = &existing

	patches := handler.createPVCPatch(pvc)
	// storageClassName은 변경하지 않아야 한다.
	if hasPatchForPath(patches, "/spec/storageClassName") {
		t.Fatalf("expected no storageClassName patch when storageClassName already set (non-replaceable), got %d patches", len(patches))
	}

	// KETI 메타데이터는 항상 merge/add 된다.
	if !hasPatchForPath(patches, "/metadata/annotations") || !hasPatchForPath(patches, "/metadata/labels") {
		t.Fatalf("expected KETI metadata patches for annotations/labels, got: %+v", patches)
	}
}

func TestPVC_ReplacesNfsClientWhenReplaceable(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-nfs-replace")
	nfs := "nfs-client"
	pvc.Spec.StorageClassName = &nfs
	pvc.Labels = map[string]string{"stage": "train", "gpuCount": "1"}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Op != "replace" || p.Value != "storage-l2" {
		t.Fatalf("expected replace storage-l2, got %+v", p)
	}
}

func TestPVC_HandleRequest_MutatesStorageClass(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-handle")
	pvc.Annotations = map[string]string{"stage": "inference"}

	req := createPVCAdmissionRequest(t, pvc)
	w := httptest.NewRecorder()
	handler.Handle(w, req)

	patches, allowed := extractPatches(t, w)
	if !allowed {
		t.Fatal("PVC should be allowed")
	}
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l3" {
		t.Fatalf("expected storage-l3 patch from Handle(), got %+v", p)
	}
}

func TestPVC_FrameworkTriton_PrefersL3(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-framework-triton")
	pvc.Labels = map[string]string{
		"workload.keti.io/framework": "triton",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l3" {
		t.Fatalf("expected storage-l3 for triton framework, got %+v", p)
	}
}

func TestPVC_FrameworkPyTorchTrain_PrefersL2(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-framework-pytorch-train")
	pvc.Annotations = map[string]string{
		"framework": "pytorch",
		"stage":     "train",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l2" {
		t.Fatalf("expected storage-l2 for pytorch train, got %+v", p)
	}
}

func TestSelectStorageClass_MountPathCache_ReadOnlyFalse(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	pvc := pvcForTierTest("pvc-mount-cache")

	pvc.Labels = map[string]string{
		"workload.keti.io/mount-path": "/cache",
		"workload.keti.io/read-only":  "false",
	}

	sc, _, _ := handler.selectStorageClass(pvc)
	if sc != storageClassL1 {
		t.Fatalf("expected %s, got %s", storageClassL1, sc)
	}
}

func TestSelectStorageClass_MountPathModel_ReadOnlyTrue(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	pvc := pvcForTierTest("pvc-mount-model")

	pvc.Labels = map[string]string{
		"workload.keti.io/mount-path": "/model",
		"workload.keti.io/read-only":  "true",
	}

	sc, _, _ := handler.selectStorageClass(pvc)
	if sc != storageClassL3 {
		t.Fatalf("expected %s, got %s", storageClassL3, sc)
	}
}

func TestSelectStorageClass_WorkloadKindStatefulSet(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	pvc := pvcForTierTest("pvc-kind-sts")

	pvc.Labels = map[string]string{
		"workload.keti.io/kind": "StatefulSet",
	}

	sc, _, _ := handler.selectStorageClass(pvc)
	if sc != storageClassL3 {
		t.Fatalf("expected %s, got %s", storageClassL3, sc)
	}
}

func TestSelectStorageClass_WorkloadKindDeployment(t *testing.T) {
	handler := NewMutationHandler(testConfig())

	pvc := pvcForTierTest("pvc-kind-dep")

	pvc.Labels = map[string]string{
		"workload.keti.io/kind": "Deployment",
	}

	sc, _, _ := handler.selectStorageClass(pvc)
	if sc != storageClassL3 {
		t.Fatalf("expected %s, got %s", storageClassL3, sc)
	}
}

// TestPVC_LegacyStorageClassName_Normalized: 기존 storage-archive(legacy) → storage-s3로 normalize되는지 확인.
func TestPVC_LegacyStorageClassName_Normalized(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-legacy-sc")
	legacy := "storage-archive"
	pvc.Spec.StorageClassName = &legacy

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Op != "replace" || p.Value != "storage-s3" {
		t.Fatalf("expected replace storage-s3 (legacy normalize), got %+v", p)
	}
}

// TestPVC_FinalTierAnnotation_Preserved: 이미 selected-tier=L2가 있으면
// PVC가 그 tier를 그대로 따르고, scoring으로 다른 결과를 강제하지 않는지 확인.
func TestPVC_FinalTierAnnotation_Preserved(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-preserve-final-tier")
	pvc.Annotations = map[string]string{
		"ai-storage/selected-tier": "L2", // 명확한 최종 tier
		"stage":                    "preprocess", // 이 정보를 무시해야 함
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l2" {
		t.Fatalf("expected storage-l2 (preserve existing L2), got %+v", p)
	}
}

// =============================================================================
// 2단계 rule 기반 tier 선정 단위 테스트 (selectTierByRules)
//
// 각 케이스는 storage.keti.io/{tier-hint, data-role, workload-type, priority}
// annotation 하나만 박힌 PVC를 생성해 createPVCPatch가 표준 storage-l1/l2/l3/s3 중
// 어떤 것을 선택하는지 검증한다. 기존 score 로직(workload.keti.io/* 등)은 의도적으로
// 비워 두어 rule 분기만 검증한다.
// =============================================================================

// 1) tier-hint=L1 → storage-l1.
func TestPVC_Rule_TierHint_L1(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-hint-l1")
	pvc.Annotations = map[string]string{
		"storage.keti.io/tier-hint": "L1",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l1" {
		t.Fatalf("expected storage-l1 (tier-hint=L1), got %+v", p)
	}
}

// 2) tier-hint=performance (legacy) → storage-l2 로 normalize.
func TestPVC_Rule_TierHint_Legacy_Performance(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-hint-perf")
	pvc.Annotations = map[string]string{
		"storage.keti.io/tier-hint": "performance",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l2" {
		t.Fatalf("expected storage-l2 (tier-hint=performance → L2), got %+v", p)
	}
}

// 3) data-role=cache → storage-l1.
func TestPVC_Rule_DataRole_Cache(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-role-cache")
	pvc.Annotations = map[string]string{
		"storage.keti.io/data-role": "cache",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l1" {
		t.Fatalf("expected storage-l1 (data-role=cache), got %+v", p)
	}
}

// 4) data-role=preprocessing-input → storage-l2.
func TestPVC_Rule_DataRole_PreprocessingInput(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-role-preproc")
	pvc.Annotations = map[string]string{
		"storage.keti.io/data-role": "preprocessing-input",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l2" {
		t.Fatalf("expected storage-l2 (data-role=preprocessing-input), got %+v", p)
	}
}

// 5) data-role=raw-dataset → storage-l3.
func TestPVC_Rule_DataRole_RawDataset(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-role-raw")
	pvc.Annotations = map[string]string{
		"storage.keti.io/data-role": "raw-dataset",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l3" {
		t.Fatalf("expected storage-l3 (data-role=raw-dataset), got %+v", p)
	}
}

// 6) data-role=result-backup → storage-s3.
func TestPVC_Rule_DataRole_ResultBackup(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-role-backup")
	pvc.Annotations = map[string]string{
		"storage.keti.io/data-role": "result-backup",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-s3" {
		t.Fatalf("expected storage-s3 (data-role=result-backup), got %+v", p)
	}
}

// 7) workload-type=preprocessing 만 있음 → storage-l2.
func TestPVC_Rule_WorkloadType_Preprocessing(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-wl-preproc")
	pvc.Annotations = map[string]string{
		"storage.keti.io/workload-type": "preprocessing",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l2" {
		t.Fatalf("expected storage-l2 (workload-type=preprocessing), got %+v", p)
	}
}

// 8) workload-type=dataset-ingest 만 있음 → storage-l3.
func TestPVC_Rule_WorkloadType_DatasetIngest(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-wl-ingest")
	pvc.Annotations = map[string]string{
		"storage.keti.io/workload-type": "dataset-ingest",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l3" {
		t.Fatalf("expected storage-l3 (workload-type=dataset-ingest), got %+v", p)
	}
}

// 9) priority=high 만 있음 → storage-l2 (high여도 L1로 가지 않음).
func TestPVC_Rule_Priority_High(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-prio-high")
	pvc.Annotations = map[string]string{
		"storage.keti.io/priority": "high",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l2" {
		t.Fatalf("expected storage-l2 (priority=high → L2, never L1), got %+v", p)
	}
}

// 10) priority=low 만 있음 → storage-s3.
func TestPVC_Rule_Priority_Low(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-prio-low")
	pvc.Annotations = map[string]string{
		"storage.keti.io/priority": "low",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-s3" {
		t.Fatalf("expected storage-s3 (priority=low), got %+v", p)
	}
}

// 11) annotation/label 이 전혀 없음 → default L2(storage-l2).
func TestPVC_Rule_NoAnnotation_DefaultL2(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-empty")

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l2" {
		t.Fatalf("expected storage-l2 (no rule input → default L2), got %+v", p)
	}
}

// 12) 기존 storageClassName=storage-performance(legacy) → storage-l2 로 normalize.
//
// existingFinalTierFromPVC 가 legacy SC 이름도 정규화해 보존 경로로 들어가므로
// rule 분기와 무관하게 storage-l2 로 결과가 나와야 한다.
func TestPVC_Rule_LegacyStorageClass_Performance_Normalized(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-legacy-sc-perf")
	legacy := "storage-performance"
	pvc.Spec.StorageClassName = &legacy

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Op != "replace" || p.Value != "storage-l2" {
		t.Fatalf("expected replace storage-l2 (legacy storage-performance), got %+v", p)
	}
}

// 보강: data-role 이 priority 보다 우선되는지 확인.
//
// data-role=cache (L1) + priority=high → L1 이 나와야 한다(priority가 덮어쓰지 않음).
func TestPVC_Rule_DataRole_BeatsPriority(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-rule-role-vs-prio")
	pvc.Annotations = map[string]string{
		"storage.keti.io/data-role": "cache",
		"storage.keti.io/priority":  "high",
	}

	patches := handler.createPVCPatch(pvc)
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != "storage-l1" {
		t.Fatalf("expected storage-l1 (data-role=cache beats priority=high), got %+v", p)
	}
}

// =============================================================================
// 3단계 Hard Rule + AHP Score Rule 단위 테스트
//
// 각 케이스마다:
//   - createPVCPatch 결과의 storageClassName(/spec/storageClassName) 검증
//   - tier-reason annotation 에 selection-path 와 selected 가 정확히 박히는지 검증
// =============================================================================

// tierReasonValueOf는 patch 결과에서 ai-storage/tier-reason annotation 값을 추출한다.
func tierReasonValueOf(patches []patchOperation) string {
	for _, p := range patches {
		if p.Path == "/metadata/annotations/ai-storage~1tier-reason" {
			if s, ok := p.Value.(string); ok {
				return s
			}
		}
		if p.Path == "/metadata/annotations" {
			if m, ok := p.Value.(map[string]string); ok {
				if v, exists := m["ai-storage/tier-reason"]; exists {
					return v
				}
			}
		}
	}
	return ""
}

func assertTierSelection(t *testing.T, patches []patchOperation, expectedSC, expectedPath, expectedTier string) {
	t.Helper()
	p := getPatchForPath(patches, "/spec/storageClassName")
	if p == nil || p.Value != expectedSC {
		t.Fatalf("expected storageClassName=%s, got %+v", expectedSC, p)
	}
	reason := tierReasonValueOf(patches)
	if reason == "" {
		t.Fatalf("expected tier-reason annotation, got none")
	}
	if !contains(reason, "selection-path="+expectedPath) {
		t.Fatalf("expected selection-path=%s in tier-reason, got %q", expectedPath, reason)
	}
	if !contains(reason, "selected="+expectedTier) {
		t.Fatalf("expected selected=%s in tier-reason, got %q", expectedTier, reason)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && indexOf(haystack, needle) >= 0
}

func indexOf(haystack, needle string) int {
	if needle == "" {
		return 0
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}

// 1) preprocessing-input + high + weight=1.5 + latency=low + io-pattern=large-read → L2 (score-rule)
//
// 계산:
//   - data-role=preprocessing-input  : L2+50
//   - priority=high                  : L1+5, L2+10
//   - weight=1.5                     : L1+5, L2+5
//   - latency=low                    : L2+25
//   - io-pattern=large-read          : L2+15, L3+10
//   합계: L1=10, L2=105, L3=10, S3=0  → L2.
func TestPVC_Score_PreprocessingInput_HighWeight_LowLat_LargeRead_L2(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-s3-1-prep-input")
	pvc.Annotations = map[string]string{
		"storage.keti.io/data-role":      "preprocessing-input",
		"storage.keti.io/priority":       "high",
		"storage.keti.io/weight":         "1.5",
		"storage.keti.io/latency":        "low",
		"storage.keti.io/io-pattern":     "large-read",
	}

	patches := handler.createPVCPatch(pvc)
	assertTierSelection(t, patches, "storage-l2", "score-rule", "L2")
}

// 2) cache + access-pattern=repeated + latency=ultra-low + priority=medium → L1 (hard-rule)
func TestPVC_Hard_Cache_Repeated_UltraLow_L1(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-s3-2-cache-hard")
	pvc.Annotations = map[string]string{
		"storage.keti.io/data-role":       "cache",
		"storage.keti.io/access-pattern":  "repeated",
		"storage.keti.io/latency":         "ultra-low",
		"storage.keti.io/priority":        "medium",
	}

	patches := handler.createPVCPatch(pvc)
	assertTierSelection(t, patches, "storage-l1", "hard-rule", "L1")
}

// 3) raw-dataset + priority=high + weight=1.5 → L3 (score-rule)
//
// 계산:
//   - data-role=raw-dataset : L3+50
//   - priority=high         : L1+5, L2+10
//   - weight=1.5            : L1+5, L2+5
//   합계: L1=10, L2=15, L3=50, S3=0 → L3.
func TestPVC_Score_RawDataset_HighWeight_L3(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-s3-3-raw")
	pvc.Annotations = map[string]string{
		"storage.keti.io/data-role": "raw-dataset",
		"storage.keti.io/priority":  "high",
		"storage.keti.io/weight":    "1.5",
	}

	patches := handler.createPVCPatch(pvc)
	assertTierSelection(t, patches, "storage-l3", "score-rule", "L3")
}

// 4) result-backup + priority=high + weight=2.0 → S3 (hard-rule)
//
// data-role=result-backup 은 hard-rule 로 S3 즉시 확정한다.
// priority/weight 가 아무리 높아도 archive 계열은 L2/L1 으로 끌어올리지 않는다.
func TestPVC_Hard_ResultBackup_HighWeight_S3(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-s3-4-backup-hard")
	pvc.Annotations = map[string]string{
		"storage.keti.io/data-role": "result-backup",
		"storage.keti.io/priority":  "high",
		"storage.keti.io/weight":    "2.0",
	}

	patches := handler.createPVCPatch(pvc)
	assertTierSelection(t, patches, "storage-s3", "hard-rule", "S3")
}

// 5) workload-type=preprocessing + priority=low + data-role 없음 → L2 (score-rule).
//
// 계산:
//   - workload-type=preprocessing : L2+25
//   - priority=low                : L3+5, S3+10
//   합계: L1=0, L2=25, L3=5, S3=10 → L2.
func TestPVC_Score_WorkloadPreprocessing_LowPriority_L2(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-s3-5-wl-prep-low")
	pvc.Annotations = map[string]string{
		"storage.keti.io/workload-type": "preprocessing",
		"storage.keti.io/priority":      "low",
	}

	patches := handler.createPVCPatch(pvc)
	assertTierSelection(t, patches, "storage-l2", "score-rule", "L2")
}

// 6) priority=high 만 있음 → L2 (score-rule, L1 단독 승격 금지).
//
// 계산: priority=high → L1+5, L2+10 → L2 win.
func TestPVC_Score_HighPriorityOnly_L2(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-s3-6-prio-high-only")
	pvc.Annotations = map[string]string{
		"storage.keti.io/priority": "high",
	}

	patches := handler.createPVCPatch(pvc)
	assertTierSelection(t, patches, "storage-l2", "score-rule", "L2")
}

// 7) weight=2.0 만 있음 → L2 (tie-break: L2 > L1 동점 시 L2).
//
// 계산: weight>=1.5 → L1+5, L2+5 → 동점 → tie-break L2.
func TestPVC_Score_HighWeightOnly_L2_NotL1(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-s3-7-weight-high-only")
	pvc.Annotations = map[string]string{
		"storage.keti.io/weight": "2.0",
	}

	patches := handler.createPVCPatch(pvc)
	assertTierSelection(t, patches, "storage-l2", "score-rule", "L2")
}

// 8) tier-hint=L3 → score 보다 우선해서 L3 (hard-rule).
func TestPVC_Hard_TierHint_L3(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-s3-8-hint-l3")
	pvc.Annotations = map[string]string{
		"storage.keti.io/tier-hint": "L3",
		// 더 강한 score 시그널을 일부러 같이 박아도 무시되어야 한다.
		"storage.keti.io/data-role": "preprocessing-input",
		"storage.keti.io/priority":  "high",
	}

	patches := handler.createPVCPatch(pvc)
	assertTierSelection(t, patches, "storage-l3", "hard-rule", "L3")
}

// 9) tier-hint=performance(legacy) → L2 로 normalize (hard-rule).
func TestPVC_Hard_TierHint_Legacy_Performance_L2(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-s3-9-hint-perf")
	pvc.Annotations = map[string]string{
		"storage.keti.io/tier-hint": "performance",
	}

	patches := handler.createPVCPatch(pvc)
	assertTierSelection(t, patches, "storage-l2", "hard-rule", "L2")
}

// 10) 아무 annotation 없음 → default L2.
func TestPVC_Default_NoAnnotation_L2(t *testing.T) {
	handler := NewMutationHandler(testConfig())
	pvc := pvcForTierTest("pvc-s3-10-empty")

	patches := handler.createPVCPatch(pvc)
	assertTierSelection(t, patches, "storage-l2", "default-l2", "L2")
}
