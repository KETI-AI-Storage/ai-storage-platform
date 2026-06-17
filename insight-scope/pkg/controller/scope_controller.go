package controller

import (
	"context"
	"fmt"
	"log"
	"strconv"
	"sync"
	"time"

	"insight-scope/pkg/analyzer"
	"insight-scope/pkg/client"
	"insight-scope/pkg/detector"
	"insight-scope/pkg/types"

	"github.com/google/uuid"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/yaml"
)

// ScopeController manages AI workload scope analysis
type ScopeController struct {
	k8sClient     kubernetes.Interface
	yamlAnalyzer  *analyzer.YAMLAnalyzer
	dagAnalyzer   *analyzer.DAGAnalyzer
	modelDetector *detector.ModelDetector
	traceClient   *client.TraceClient

	// Cache of analysis results
	analysisCache map[string]*types.ScopeAnalysisResult
	cacheMux      sync.RWMutex
	cacheTTL      time.Duration

	// Configuration
	sidecarPort int
}

// NewScopeController creates a new scope controller
func NewScopeController(kubeconfig string) (*ScopeController, error) {
	var config *rest.Config
	var err error

	if kubeconfig != "" {
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
	} else {
		config, err = rest.InClusterConfig()
	}
	if err != nil {
		return nil, fmt.Errorf("failed to create kubernetes config: %w", err)
	}

	k8sClient, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create kubernetes client: %w", err)
	}

	// Create DAG analyzer (ignore error, DAG analysis is optional)
	dagAnalyzer, err := analyzer.NewDAGAnalyzer(kubeconfig)
	if err != nil {
		log.Printf("Warning: DAG analyzer initialization failed: %v", err)
	}

	return &ScopeController{
		k8sClient:     k8sClient,
		yamlAnalyzer:  analyzer.NewYAMLAnalyzer(),
		dagAnalyzer:   dagAnalyzer,
		modelDetector: detector.NewModelDetector(),
		traceClient:   client.NewTraceClient(),
		analysisCache: make(map[string]*types.ScopeAnalysisResult),
		cacheTTL:      5 * time.Minute,
		sidecarPort:   9090,
	}, nil
}

// AnalyzePod performs complete scope analysis on a pod
func (sc *ScopeController) AnalyzePod(ctx context.Context, req *types.ScopeAnalysisRequest) (*types.ScopeAnalysisResult, error) {
	startTime := time.Now()
	analysisID := uuid.New().String()[:8]

	log.Printf("Scope Analysis %s: Starting analysis for %s/%s", analysisID, req.Namespace, req.PodName)

	result := &types.ScopeAnalysisResult{
		AnalysisID:   analysisID,
		PodNamespace: req.Namespace,
		AnalyzedAt:   time.Now(),
	}

	// Get Pod spec
	var pod *corev1.Pod
	var err error

	if req.PodYAML != "" {
		// Parse from YAML string
		pod, err = sc.parsePodYAML(req.PodYAML)
		if err != nil {
			return nil, fmt.Errorf("failed to parse pod yaml: %w", err)
		}
	} else if req.PodName != "" && req.Namespace != "" {
		// Fetch from Kubernetes
		pod, err = sc.k8sClient.CoreV1().Pods(req.Namespace).Get(ctx, req.PodName, metav1.GetOptions{})
		if err != nil {
			return nil, fmt.Errorf("failed to get pod: %w", err)
		}
	} else {
		return nil, fmt.Errorf("either pod_yaml or pod_name/namespace must be provided")
	}

	result.PodName = pod.Name
	result.PodNamespace = pod.Namespace

	// Step 1: YAML Analysis (정적 분석)
	log.Printf("Scope Analysis %s: Performing YAML analysis", analysisID)
	result.YAMLAnalysis = sc.yamlAnalyzer.AnalyzePod(pod)

	// Find main container name
	if len(pod.Spec.Containers) > 0 {
		result.ContainerName = sc.findMainContainerName(pod)
	}

	// Step 2: Trace Analysis (동적 분석 - Insight Trace 연동)
	if req.IncludeTraceData && pod.Status.PodIP != "" {
		log.Printf("Scope Analysis %s: Fetching Insight Trace data", analysisID)
		result.TraceAnalysis = sc.fetchTraceAnalysis(ctx, pod, req.WaitForTrace)
	}

	// Step 2.5: DAG Analysis (Argo Workflow DAG 분석)
	if sc.dagAnalyzer != nil && pod.Labels != nil {
		if _, hasWorkflow := pod.Labels["workflows.argoproj.io/workflow"]; hasWorkflow {
			log.Printf("Scope Analysis %s: Analyzing Argo Workflow DAG", analysisID)
			result.DAGAnalysis = sc.dagAnalyzer.AnalyzeFromPod(ctx, pod.Labels, pod.Namespace)
		}
	}

	// Step 2.6: Shard Analysis
	result.ShardAnalysis = sc.extractShardAnalysis(pod, result.TraceAnalysis)

	// Step 3: AI Model Detection (통합 분석)
	log.Printf("Scope Analysis %s: Detecting AI model", analysisID)
	yamlSignature := sc.modelDetector.DetectFromYAML(result.YAMLAnalysis)

	var traceSignature *types.AIModelSignature
	if result.TraceAnalysis != nil && result.TraceAnalysis.TraceAvailable {
		traceSignature = sc.modelDetector.DetectFromTrace(result.TraceAnalysis)
	}

	// Combine detections
	result.ModelSignature = sc.modelDetector.CombineDetections(yamlSignature, traceSignature)

	// Step 4: Determine current stage
	result.CurrentStage = sc.determineCurrentStage(result)

	// Step 5: Generate storage recommendations
	result.StorageRecommendation = sc.generateStorageRecommendation(result)

	result.AnalysisDuration = float64(time.Since(startTime).Milliseconds())

	// Cache result
	sc.cacheResult(result)

	log.Printf("Scope Analysis %s: Completed in %.2fms - Model: %s, Category: %s, Stage: %s",
		analysisID, result.AnalysisDuration,
		result.ModelSignature.ModelType,
		result.ModelSignature.ModelCategory,
		result.CurrentStage)

	return result, nil
}

// parsePodYAML parses a Pod from YAML string
func (sc *ScopeController) parsePodYAML(yamlStr string) (*corev1.Pod, error) {
	var pod corev1.Pod
	if err := yaml.Unmarshal([]byte(yamlStr), &pod); err != nil {
		return nil, err
	}
	return &pod, nil
}

// findMainContainerName finds the main container (not sidecar)
func (sc *ScopeController) findMainContainerName(pod *corev1.Pod) string {
	sidecarNames := []string{"insight-trace", "istio-proxy", "envoy", "sidecar"}

	for _, c := range pod.Spec.Containers {
		isSidecar := false
		for _, sc := range sidecarNames {
			if c.Name == sc || contains(c.Name, sc) {
				isSidecar = true
				break
			}
		}
		if !isSidecar {
			return c.Name
		}
	}

	// Fallback to first container
	if len(pod.Spec.Containers) > 0 {
		return pod.Spec.Containers[0].Name
	}
	return ""
}

// fetchTraceAnalysis fetches analysis from Insight Trace sidecar
func (sc *ScopeController) fetchTraceAnalysis(ctx context.Context, pod *corev1.Pod, wait bool) *types.TraceAnalysisResult {
	// Check if pod has Insight Trace sidecar
	hasInsightTrace := false
	for _, c := range pod.Spec.Containers {
		if c.Name == "insight-trace" || contains(c.Name, "insight-trace") {
			hasInsightTrace = true
			break
		}
	}

	if !hasInsightTrace {
		log.Printf("Pod %s/%s does not have Insight Trace sidecar", pod.Namespace, pod.Name)
		return &types.TraceAnalysisResult{TraceAvailable: false}
	}

	// Get endpoint
	endpoint := client.GetSidecarEndpoint(pod.Status.PodIP, sc.sidecarPort)

	// Try to fetch with optional wait
	maxRetries := 1
	if wait {
		maxRetries = 5
	}

	for i := 0; i < maxRetries; i++ {
		result, err := sc.traceClient.FetchTraceAnalysis(ctx, endpoint)
		if err == nil && result.TraceAvailable {
			return result
		}

		if wait && i < maxRetries-1 {
			log.Printf("Waiting for Insight Trace data (attempt %d/%d)", i+1, maxRetries)
			time.Sleep(5 * time.Second)
		}
	}

	return &types.TraceAnalysisResult{TraceAvailable: false}
}

// determineCurrentStage determines the current pipeline stage
func (sc *ScopeController) determineCurrentStage(result *types.ScopeAnalysisResult) types.PipelineStage {
	// Prioritize trace data (runtime)
	if result.TraceAnalysis != nil && result.TraceAnalysis.TraceAvailable {
		if result.TraceAnalysis.DetectedStage != types.StageUnknown {
			return result.TraceAnalysis.DetectedStage
		}
	}

	// Fall back to YAML analysis
	if result.YAMLAnalysis != nil && result.YAMLAnalysis.InferredStage != types.StageUnknown {
		return result.YAMLAnalysis.InferredStage
	}

	// Fall back to model signature
	if result.ModelSignature != nil {
		return types.StageUnknown
	}

	return types.StageUnknown
}

// generateStorageRecommendation generates storage recommendations
func (sc *ScopeController) generateStorageRecommendation(result *types.ScopeAnalysisResult) *types.StorageRecommendation {
	rec := &types.StorageRecommendation{
		AccessMode: "ReadWriteOnce",
	}

	if result.ModelSignature != nil {
		rec.StorageClass = result.ModelSignature.RecommendedStorageClass
		rec.StorageSize = result.ModelSignature.RecommendedStorageSize
		rec.IOPS = result.ModelSignature.RecommendedIOPS
		rec.ThroughputMBps = result.ModelSignature.RecommendedThroughput
		rec.Reasoning = sc.generateReasoningText(result)

		// Determine cache tier based on I/O pattern
		switch result.ModelSignature.IOPattern {
		case types.IOPatternSequentialRead:
			rec.CacheTier = "nvme"
			rec.Reasoning += " NVMe caching recommended for sequential read workloads."
		case types.IOPatternRandomRead:
			rec.CacheTier = "ssd"
			rec.Reasoning += " SSD caching recommended for random access patterns."
		default:
			rec.CacheTier = "ssd"
		}

		// Adjust for stage
		switch result.CurrentStage {
		case types.StageTraining:
			// Training needs more storage for checkpoints
			rec.StorageSize = sc.increaseSize(rec.StorageSize, 1.5)
			rec.Reasoning += " Training stage requires additional storage for checkpoints."
		case types.StagePreprocesing:
			// Preprocessing may need temporary space
			rec.StorageSize = sc.increaseSize(rec.StorageSize, 1.2)
		}

		// Determine alternative class
		switch rec.StorageClass {
		case "high-throughput":
			rec.AlternativeClass = "balanced"
		case "high-iops":
			rec.AlternativeClass = "balanced"
		case "balanced":
			rec.AlternativeClass = "standard"
		}
	} else {
		// Default recommendations
		rec.StorageClass = "standard"
		rec.StorageSize = "200Gi"
		rec.IOPS = 3000
		rec.ThroughputMBps = 200
		rec.CacheTier = "ssd"
		rec.Reasoning = "Default recommendations (no model detected)"
	}

	return rec
}

// generateReasoningText generates human-readable reasoning
func (sc *ScopeController) generateReasoningText(result *types.ScopeAnalysisResult) string {
	var reasoning string

	if result.ModelSignature != nil {
		reasoning = fmt.Sprintf("Based on detected %s model (%s category)",
			result.ModelSignature.ModelType,
			result.ModelSignature.ModelCategory)

		if result.ModelSignature.Framework != types.FrameworkUnknown {
			reasoning += fmt.Sprintf(" using %s framework", result.ModelSignature.Framework)
		}

		reasoning += fmt.Sprintf(". I/O pattern: %s with %.0f%% read ratio.",
			result.ModelSignature.IOPattern,
			result.ModelSignature.ReadWriteRatio*100)
	}

	return reasoning
}

// increaseSize increases a storage size by a factor
func (sc *ScopeController) increaseSize(size string, factor float64) string {
	// Simple parsing - assume format like "200Gi"
	var value int
	var unit string

	if n, _ := fmt.Sscanf(size, "%d%s", &value, &unit); n == 2 {
		newValue := int(float64(value) * factor)
		return fmt.Sprintf("%d%s", newValue, unit)
	}

	return size
}

// cacheResult caches the analysis result
func (sc *ScopeController) cacheResult(result *types.ScopeAnalysisResult) {
	key := fmt.Sprintf("%s/%s", result.PodNamespace, result.PodName)

	sc.cacheMux.Lock()
	sc.analysisCache[key] = result
	sc.cacheMux.Unlock()
}

// GetCachedAnalysis retrieves a cached analysis result
func (sc *ScopeController) GetCachedAnalysis(namespace, podName string) *types.ScopeAnalysisResult {
	key := fmt.Sprintf("%s/%s", namespace, podName)

	sc.cacheMux.RLock()
	result, exists := sc.analysisCache[key]
	sc.cacheMux.RUnlock()

	if !exists {
		return nil
	}

	// Check TTL
	if time.Since(result.AnalyzedAt) > sc.cacheTTL {
		sc.cacheMux.Lock()
		delete(sc.analysisCache, key)
		sc.cacheMux.Unlock()
		return nil
	}

	return result
}

// ListCachedAnalyses returns all cached analyses
func (sc *ScopeController) ListCachedAnalyses() []*types.ScopeAnalysisResult {
	sc.cacheMux.RLock()
	defer sc.cacheMux.RUnlock()

	results := make([]*types.ScopeAnalysisResult, 0, len(sc.analysisCache))
	for _, result := range sc.analysisCache {
		if time.Since(result.AnalyzedAt) <= sc.cacheTTL {
			results = append(results, result)
		}
	}

	return results
}

// AnalyzeAllPods analyzes all pods in a namespace with Insight Trace
func (sc *ScopeController) AnalyzeAllPods(ctx context.Context, namespace string) ([]*types.ScopeAnalysisResult, error) {
	pods, err := sc.k8sClient.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
		LabelSelector: "insight-trace=enabled",
	})
	if err != nil {
		return nil, fmt.Errorf("failed to list pods: %w", err)
	}

	var results []*types.ScopeAnalysisResult
	for _, pod := range pods.Items {
		if pod.Status.Phase != corev1.PodRunning {
			continue
		}

		result, err := sc.AnalyzePod(ctx, &types.ScopeAnalysisRequest{
			PodName:          pod.Name,
			Namespace:        pod.Namespace,
			IncludeTraceData: true,
		})
		if err != nil {
			log.Printf("Failed to analyze pod %s/%s: %v", pod.Namespace, pod.Name, err)
			continue
		}
		results = append(results, result)
	}

	return results, nil
}

// GetModelProfile returns the profile for a known model type
func (sc *ScopeController) GetModelProfile(modelType types.AIModelType) *types.ModelProfile {
	return sc.modelDetector.GetModelProfile(modelType)
}

// SearchModels searches for models by keyword
func (sc *ScopeController) SearchModels(keyword string) []types.AIModelType {
	return sc.modelDetector.SearchModelByKeyword(keyword)
}

// ListAllModels returns all known model types
func (sc *ScopeController) ListAllModels() []types.AIModelType {
	return sc.modelDetector.ListAllModels()
}

// traceCarriesShardInput은 trace가 실제 스캔 기반 shard 메타를 포함하는지 판별한다.
func traceCarriesShardInput(trace *types.TraceAnalysisResult) bool {
	if trace == nil || !trace.TraceAvailable || trace.ShardMetadata == nil {
		return false
	}
	m := trace.ShardMetadata
	if m.ShardScanError != "" {
		return true
	}
	return m.ShardPath != "" || m.ShardCount > 0 || len(m.ShardPaths) > 0
}

// extractShardAnalysis은 Pod/Trace 메타를 기반으로 shard 분석 결과를 생성한다.
func (sc *ScopeController) extractShardAnalysis(pod *corev1.Pod, trace *types.TraceAnalysisResult) *types.ShardAnalysis {
	if traceCarriesShardInput(trace) {
		return buildShardAnalysis(trace.ShardMetadata)
	}

	// trace에 shard 입력 메타가 없을 때만 annotation fallback
	if pod == nil || pod.Annotations == nil {
		return nil
	}
	path := pod.Annotations["ai-storage.keti/shard-path"]
	if path == "" {
		return nil
	}
	count, _ := strconv.Atoi(pod.Annotations["ai-storage.keti/shard-count"])
	index, _ := strconv.Atoi(pod.Annotations["ai-storage.keti/shard-index"])
	size, _ := strconv.ParseInt(pod.Annotations["ai-storage.keti/shard-size-bytes"], 10, 64)
	meta := &types.ShardMetadata{
		ShardCount:     count,
		ShardIndex:     index,
		ShardPath:      path,
		ShardSizeBytes: size,
		ShardSource:    "annotation_fallback",
	}
	return buildShardAnalysis(meta)
}

func buildShardAnalysis(meta *types.ShardMetadata) *types.ShardAnalysis {
	if meta == nil {
		return nil
	}
	div := meta.ShardCount
	if div < 1 {
		div = 1
	}
	return &types.ShardAnalysis{
		ShardCount:      meta.ShardCount,
		ShardIndex:      meta.ShardIndex,
		ShardPath:       meta.ShardPath,
		ShardSizeBytes:  meta.ShardSizeBytes,
		RelativeWeight:  float64(meta.ShardSizeBytes) / float64(div),
		DistributionKey: fmt.Sprintf("%s#%d/%d", meta.ShardPath, meta.ShardIndex, div),
		Source:          meta.ShardSource,
		PathSampleCount: len(meta.ShardPaths),
		TarHeaderCount:  meta.TarHeaderCount,
		ScanError:       meta.ShardScanError,
	}
}

// Helper function
func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(substr) == 0 ||
		(len(s) > 0 && len(substr) > 0 && s[0:len(substr)] == substr) ||
		(len(s) > len(substr) && s[len(s)-len(substr):] == substr) ||
		(len(s) > len(substr) && findSubstring(s, substr)))
}

func findSubstring(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
