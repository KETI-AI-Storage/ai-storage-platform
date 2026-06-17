package analyzer

import (
	"strconv"
	"strings"

	"insight-scope/pkg/types"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
)

// =====================================================
// Volume Analyzer
// =====================================================

// VolumeAnalyzer analyzes volume mounts
type VolumeAnalyzer struct {
	purposePatterns map[string][]string
}

// NewVolumeAnalyzer creates a new volume analyzer
func NewVolumeAnalyzer() *VolumeAnalyzer {
	va := &VolumeAnalyzer{
		purposePatterns: make(map[string][]string),
	}
	va.initPatterns()
	return va
}

func (va *VolumeAnalyzer) initPatterns() {
	// Purpose detection patterns based on mount path
	va.purposePatterns["data"] = []string{
		"/data", "/dataset", "/datasets", "/input", "/train",
		"/images", "/corpus", "/raw", "/source",
	}
	va.purposePatterns["model"] = []string{
		"/model", "/models", "/weights", "/pretrained",
		"/checkpoints", "/ckpt", "/saved_model",
	}
	va.purposePatterns["checkpoint"] = []string{
		"/checkpoint", "/checkpoints", "/ckpt", "/snapshots",
		"/backup", "/resume",
	}
	va.purposePatterns["output"] = []string{
		"/output", "/outputs", "/results", "/predictions",
		"/logs", "/tensorboard", "/mlruns",
	}
	va.purposePatterns["cache"] = []string{
		"/cache", "/.cache", "/tmp", "/scratch",
		"/huggingface", "/torch", "/transformers",
	}
	va.purposePatterns["config"] = []string{
		"/config", "/configs", "/etc", "/settings",
	}
}

// Analyze analyzes a volume mount
func (va *VolumeAnalyzer) Analyze(mount *corev1.VolumeMount, volume *corev1.Volume) *types.VolumeAnalysis {
	result := &types.VolumeAnalysis{
		VolumeName: mount.Name,
		MountPath:  mount.MountPath,
		ReadOnly:   mount.ReadOnly,
		IOPattern:  types.IOPatternBalanced,
	}

	// Determine volume type
	if volume != nil {
		result.VolumeType = va.getVolumeType(volume)
	}

	// Detect purpose from mount path
	mountPathLower := strings.ToLower(mount.MountPath)
	for purpose, patterns := range va.purposePatterns {
		for _, pattern := range patterns {
			if strings.Contains(mountPathLower, pattern) {
				result.PurposeEstimate = purpose
				break
			}
		}
		if result.PurposeEstimate != "" {
			break
		}
	}

	// Infer I/O pattern and read/write ratio based on purpose
	switch result.PurposeEstimate {
	case "data":
		result.IOPattern = types.IOPatternSequentialRead
		result.ReadWriteRatio = 0.95 // Mostly reads
		result.EstimatedSize = "100Gi"
	case "model":
		result.IOPattern = types.IOPatternSequentialRead
		result.ReadWriteRatio = 0.9
		result.EstimatedSize = "10Gi"
	case "checkpoint":
		result.IOPattern = types.IOPatternBurstWrite
		result.ReadWriteRatio = 0.3 // Mostly writes
		result.EstimatedSize = "50Gi"
	case "output":
		result.IOPattern = types.IOPatternWriteHeavy
		result.ReadWriteRatio = 0.1 // Mostly writes
		result.EstimatedSize = "20Gi"
	case "cache":
		result.IOPattern = types.IOPatternRandomRead
		result.ReadWriteRatio = 0.6 // Mixed
		result.EstimatedSize = "30Gi"
	case "config":
		result.IOPattern = types.IOPatternRandomRead
		result.ReadWriteRatio = 0.99 // Almost all reads
		result.EstimatedSize = "100Mi"
	default:
		result.IOPattern = types.IOPatternBalanced
		result.ReadWriteRatio = 0.5
		result.EstimatedSize = "10Gi"
	}

	// Override based on ReadOnly flag
	if mount.ReadOnly {
		result.ReadWriteRatio = 1.0
		if result.IOPattern == types.IOPatternWriteHeavy || result.IOPattern == types.IOPatternBurstWrite {
			result.IOPattern = types.IOPatternSequentialRead
		}
	}

	return result
}

// getVolumeType returns the type of volume
func (va *VolumeAnalyzer) getVolumeType(volume *corev1.Volume) string {
	if volume.PersistentVolumeClaim != nil {
		return "PVC"
	}
	if volume.EmptyDir != nil {
		return "EmptyDir"
	}
	if volume.ConfigMap != nil {
		return "ConfigMap"
	}
	if volume.Secret != nil {
		return "Secret"
	}
	if volume.HostPath != nil {
		return "HostPath"
	}
	if volume.NFS != nil {
		return "NFS"
	}
	if volume.CSI != nil {
		return "CSI"
	}
	return "Unknown"
}

// =====================================================
// Resource Analyzer
// =====================================================

// ResourceAnalyzer analyzes resource requests and limits
type ResourceAnalyzer struct{}

// NewResourceAnalyzer creates a new resource analyzer
func NewResourceAnalyzer() *ResourceAnalyzer {
	return &ResourceAnalyzer{}
}

// Analyze analyzes resource requirements
func (ra *ResourceAnalyzer) Analyze(resources *corev1.ResourceRequirements) *types.ResourceAnalysis {
	result := &types.ResourceAnalysis{
		IOBottleneckRisk: "low",
		Confidence:       0.6,
	}

	// Parse CPU
	if cpu, ok := resources.Requests[corev1.ResourceCPU]; ok {
		result.CPURequest = cpu.String()
	}
	if cpu, ok := resources.Limits[corev1.ResourceCPU]; ok {
		result.CPULimit = cpu.String()
	}

	// Parse Memory
	if mem, ok := resources.Requests[corev1.ResourceMemory]; ok {
		result.MemoryRequest = mem.String()
	}
	if mem, ok := resources.Limits[corev1.ResourceMemory]; ok {
		result.MemoryLimit = mem.String()
	}

	// Parse GPU
	gpuResources := []corev1.ResourceName{
		"nvidia.com/gpu",
		"amd.com/gpu",
		"intel.com/gpu",
	}
	for _, gpuRes := range gpuResources {
		if gpu, ok := resources.Limits[gpuRes]; ok {
			result.GPURequest = int(gpu.Value())
			result.GPUType = string(gpuRes)
			break
		}
		if gpu, ok := resources.Requests[gpuRes]; ok {
			result.GPURequest = int(gpu.Value())
			result.GPUType = string(gpuRes)
			break
		}
	}

	// Estimate I/O requirements based on resources
	ra.estimateIORequirements(result)

	return result
}

// estimateIORequirements estimates I/O requirements based on CPU/Memory/GPU
func (ra *ResourceAnalyzer) estimateIORequirements(result *types.ResourceAnalysis) {
	// Parse memory to estimate throughput needs
	var memoryGi float64
	if result.MemoryRequest != "" {
		mem, err := resource.ParseQuantity(result.MemoryRequest)
		if err == nil {
			memoryGi = float64(mem.Value()) / (1024 * 1024 * 1024)
		}
	}

	// Parse CPU cores
	var cpuCores float64
	if result.CPURequest != "" {
		cpu, err := resource.ParseQuantity(result.CPURequest)
		if err == nil {
			cpuCores = float64(cpu.MilliValue()) / 1000.0
		}
	}

	// Estimate based on resource profile
	if result.GPURequest > 0 {
		// GPU workload - needs high throughput
		result.EstimatedThroughput = 500 + int64(result.GPURequest*200) // MB/s
		result.EstimatedIOPS = 5000 + int64(result.GPURequest*2000)

		// Check for I/O bottleneck risk
		// High GPU count with low memory = potential I/O bottleneck
		if result.GPURequest >= 4 && memoryGi < 64 {
			result.IOBottleneckRisk = "high"
		} else if result.GPURequest >= 2 && memoryGi < 32 {
			result.IOBottleneckRisk = "medium"
		}
		result.Confidence = 0.8
	} else if cpuCores > 8 {
		// CPU-heavy workload
		result.EstimatedThroughput = 200 + int64(cpuCores*20)
		result.EstimatedIOPS = 2000 + int64(cpuCores*500)

		if memoryGi < cpuCores*2 {
			result.IOBottleneckRisk = "medium"
		}
		result.Confidence = 0.7
	} else {
		// Light workload
		result.EstimatedThroughput = 100
		result.EstimatedIOPS = 1000
		result.Confidence = 0.5
	}
}

// =====================================================
// Annotation Analyzer
// =====================================================

// AnnotationAnalyzer analyzes labels and annotations
type AnnotationAnalyzer struct {
	knownLabels      map[string]string
	knownAnnotations map[string]string
}

// NewAnnotationAnalyzer creates a new annotation analyzer
func NewAnnotationAnalyzer() *AnnotationAnalyzer {
	return &AnnotationAnalyzer{
		knownLabels: map[string]string{
			"app.kubernetes.io/component": "component",
			"app.kubernetes.io/name":      "name",
			"kubeflow.org/job":            "kubeflow",
			"training.kubeflow.org/job-name": "kubeflow",
			"volcano.sh/job-name":         "volcano",
		},
		knownAnnotations: map[string]string{
			"insight.keti.re.kr/workload-type":  "workload",
			"insight.keti.re.kr/model-type":     "model",
			"insight.keti.re.kr/pipeline-stage": "stage",
			"insight.keti.re.kr/framework":      "framework",
		},
	}
}

// Analyze analyzes labels and annotations
func (aa *AnnotationAnalyzer) Analyze(labels, annotations map[string]string) *types.AnnotationAnalysis {
	result := &types.AnnotationAnalysis{
		Labels:      labels,
		Annotations: annotations,
	}

	// Check for explicit hints in annotations
	if workload, ok := annotations["insight.keti.re.kr/workload-type"]; ok {
		result.ExplicitWorkload = workload
	}
	if model, ok := annotations["insight.keti.re.kr/model-type"]; ok {
		result.ExplicitModel = model
	}
	if stage, ok := annotations["insight.keti.re.kr/pipeline-stage"]; ok {
		result.ExplicitStage = stage
	}

	// Check for Kubeflow job
	kubeflowKeys := []string{
		"kubeflow.org/job",
		"training.kubeflow.org/job-name",
		"training.kubeflow.org/job-role",
	}
	for _, key := range kubeflowKeys {
		if val, ok := labels[key]; ok {
			result.KubeflowJob = val
			break
		}
	}

	// Check for Volcano job
	volcanoKeys := []string{
		"volcano.sh/job-name",
		"volcano.sh/queue-name",
	}
	for _, key := range volcanoKeys {
		if val, ok := labels[key]; ok {
			result.VolcanoJob = val
			break
		}
	}

	// Check for Insight Trace sidecar
	if val, ok := labels["insight-trace"]; ok && val == "enabled" {
		result.HasInsightTrace = true
	}

	// Parse implicit hints from common labels
	for k, v := range labels {
		kLower := strings.ToLower(k)
		vLower := strings.ToLower(v)

		// Try to detect stage from labels
		if strings.Contains(kLower, "stage") || strings.Contains(kLower, "phase") {
			if result.ExplicitStage == "" {
				result.ExplicitStage = v
			}
		}

		// Try to detect model from labels
		modelKeywords := []string{"bert", "gpt", "llama", "resnet", "yolo", "whisper"}
		for _, mw := range modelKeywords {
			if strings.Contains(vLower, mw) {
				if result.ExplicitModel == "" {
					result.ExplicitModel = mw
				}
				break
			}
		}
	}

	return result
}

// =====================================================
// Helper Functions
// =====================================================

// parseMemorySize parses a memory size string (e.g., "4Gi") to bytes
func parseMemorySize(size string) int64 {
	if size == "" {
		return 0
	}

	size = strings.ToUpper(strings.TrimSpace(size))
	multiplier := int64(1)

	if strings.HasSuffix(size, "GI") || strings.HasSuffix(size, "G") {
		multiplier = 1024 * 1024 * 1024
		size = strings.TrimSuffix(strings.TrimSuffix(size, "GI"), "G")
	} else if strings.HasSuffix(size, "MI") || strings.HasSuffix(size, "M") {
		multiplier = 1024 * 1024
		size = strings.TrimSuffix(strings.TrimSuffix(size, "MI"), "M")
	} else if strings.HasSuffix(size, "KI") || strings.HasSuffix(size, "K") {
		multiplier = 1024
		size = strings.TrimSuffix(strings.TrimSuffix(size, "KI"), "K")
	}

	val, err := strconv.ParseInt(size, 10, 64)
	if err != nil {
		return 0
	}
	return val * multiplier
}
