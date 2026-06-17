package client

import (
	"context"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/http"
	"strings"
	"time"

	"insight-scope/pkg/types"
)

// TraceClient is a client for Insight Trace sidecar
type TraceClient struct {
	httpClient *http.Client
	timeout    time.Duration
}

// TraceSignatureResponse represents the response from /signature endpoint
type TraceSignatureResponse struct {
	PodName                 string              `json:"pod_name"`
	PodNamespace            string              `json:"pod_namespace"`
	ContainerName           string              `json:"container_name"`
	DetectedWorkloadType    string              `json:"detected_workload_type"`
	DetectedStage           string              `json:"current_stage"`
	DetectedIOPattern       string              `json:"detected_io_pattern"`
	DetectedFramework       string              `json:"detected_framework"`
	IsGPUWorkload           bool                `json:"is_gpu_workload"`
	Confidence              float64             `json:"confidence"`
	RecommendedStorageClass string              `json:"recommended_storage_class"`
	RecommendedStorageSize  string              `json:"recommended_storage_size"`
	RecommendedIOPS         int64               `json:"recommended_iops"`
	RecommendedThroughput   int64               `json:"recommended_throughput_mbps"`
	ShardCount              int                 `json:"shard_count,omitempty"`
	ShardIndex              int                 `json:"shard_index,omitempty"`
	ShardPath               string              `json:"shard_path,omitempty"`
	ShardSizeBytes          int64               `json:"shard_size_bytes,omitempty"`
	ShardMetadata           *TraceShardScanJSON `json:"shard_metadata,omitempty"`
}

// TraceShardScanJSON은 insight-trace /signature 의 shard_metadata 객체와 동일한 JSON 형태다.
type TraceShardScanJSON struct {
	ShardPath      string   `json:"shard_path"`
	ShardSizeBytes int64    `json:"shard_size_bytes"`
	ShardCount     int      `json:"shard_count"`
	ShardIndex     int      `json:"shard_index"`
	ShardPaths     []string `json:"shard_paths,omitempty"`
	ShardEntries   []string `json:"shard_entries,omitempty"`
	ShardSource    string   `json:"shard_source"`
	ShardScanError string   `json:"shard_scan_error,omitempty"`
	TarHeaderCount int      `json:"tar_header_count,omitempty"`
}

// TraceMetricsResponse represents the response from /metrics endpoint
type TraceMetricsResponse struct {
	CurrentMetrics  *CurrentMetrics  `json:"current_metrics"`
	CurrentStage    string           `json:"current_stage"`
	WorkloadType    string           `json:"workload_type"`
	IOPattern       string           `json:"io_pattern"`
	IsGPUWorkload   bool             `json:"is_gpu_workload"`
	Framework       string           `json:"framework"`
	Recommendations *Recommendations `json:"recommendations"`
}

// CurrentMetrics represents current resource metrics
type CurrentMetrics struct {
	Timestamp            time.Time `json:"timestamp"`
	CPUUsagePercent      float64   `json:"cpu_usage_percent"`
	MemoryUsagePercent   float64   `json:"memory_usage_percent"`
	MemoryUsageBytes     int64     `json:"memory_usage_bytes"`
	GPUUsagePercent      float64   `json:"gpu_usage_percent"`
	GPUMemoryUsedMB      int64     `json:"gpu_memory_used_mb"`
	DiskReadBytesPerSec  float64   `json:"disk_read_bytes_per_sec"`
	DiskWriteBytesPerSec float64   `json:"disk_write_bytes_per_sec"`
}

// Recommendations from Insight Trace
type Recommendations struct {
	StorageClass string `json:"storage_class"`
	StorageSize  string `json:"storage_size"`
	IOPS         int64  `json:"iops"`
	Throughput   int64  `json:"throughput"`
}

// TraceResponse represents the response from /trace endpoint
type TraceResponse struct {
	TraceID          string                  `json:"trace_id"`
	PodName          string                  `json:"pod_name"`
	PodNamespace     string                  `json:"pod_namespace"`
	NodeName         string                  `json:"node_name"`
	IsActive         bool                    `json:"is_active"`
	CurrentSignature *TraceSignatureResponse `json:"current_signature"`
	StageHistory     []StageHistoryItem      `json:"stage_history"`
	StartTime        time.Time               `json:"start_time"`
}

// StageHistoryItem represents a stage in history
type StageHistoryItem struct {
	Stage             string     `json:"stage"`
	StartTime         time.Time  `json:"start_time"`
	EndTime           *time.Time `json:"end_time,omitempty"`
	Duration          float64    `json:"duration_seconds,omitempty"`
	AvgCPUUsage       float64    `json:"avg_cpu_usage_percent"`
	AvgMemoryUsage    float64    `json:"avg_memory_usage_percent"`
	AvgGPUUsage       float64    `json:"avg_gpu_usage_percent"`
	TotalReadBytes    int64      `json:"total_read_bytes"`
	TotalWriteBytes   int64      `json:"total_write_bytes"`
	ReadWriteRatio    float64    `json:"read_write_ratio"`
	DetectedIOPattern string     `json:"detected_io_pattern"`
}

// NewTraceClient creates a new Insight Trace client
func NewTraceClient() *TraceClient {
	return &TraceClient{
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
		timeout: 10 * time.Second,
	}
}

// GetSignature fetches the workload signature from Insight Trace sidecar
func (tc *TraceClient) GetSignature(ctx context.Context, endpoint string) (*TraceSignatureResponse, error) {
	url := tc.buildURL(endpoint, "/signature")

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := tc.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch signature: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	var signature TraceSignatureResponse
	if err := json.Unmarshal(body, &signature); err != nil {
		return nil, fmt.Errorf("failed to parse signature: %w", err)
	}

	return &signature, nil
}

// GetMetrics fetches current metrics from Insight Trace sidecar
func (tc *TraceClient) GetMetrics(ctx context.Context, endpoint string) (*TraceMetricsResponse, error) {
	url := tc.buildURL(endpoint, "/metrics")

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := tc.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch metrics: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	var metrics TraceMetricsResponse
	if err := json.Unmarshal(body, &metrics); err != nil {
		return nil, fmt.Errorf("failed to parse metrics: %w", err)
	}

	return &metrics, nil
}

// GetTrace fetches the full trace from Insight Trace sidecar
func (tc *TraceClient) GetTrace(ctx context.Context, endpoint string) (*TraceResponse, error) {
	url := tc.buildURL(endpoint, "/trace")

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := tc.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch trace: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	var trace TraceResponse
	if err := json.Unmarshal(body, &trace); err != nil {
		return nil, fmt.Errorf("failed to parse trace: %w", err)
	}

	return &trace, nil
}

// CheckHealth checks if the Insight Trace sidecar is healthy
func (tc *TraceClient) CheckHealth(ctx context.Context, endpoint string) (bool, error) {
	url := tc.buildURL(endpoint, "/health")

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return false, err
	}

	resp, err := tc.httpClient.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()

	return resp.StatusCode == http.StatusOK, nil
}

// FetchTraceAnalysis fetches and converts trace data to TraceAnalysisResult
func (tc *TraceClient) FetchTraceAnalysis(ctx context.Context, endpoint string) (*types.TraceAnalysisResult, error) {
	// Check health first
	healthy, err := tc.CheckHealth(ctx, endpoint)
	if err != nil || !healthy {
		return &types.TraceAnalysisResult{
			TraceAvailable: false,
		}, nil
	}

	// Fetch signature
	signature, err := tc.GetSignature(ctx, endpoint)
	if err != nil {
		return &types.TraceAnalysisResult{
			TraceAvailable: false,
		}, nil
	}

	// Fetch metrics
	metrics, err := tc.GetMetrics(ctx, endpoint)
	if err != nil {
		return &types.TraceAnalysisResult{
			TraceAvailable: false,
		}, nil
	}

	// Fetch trace for history
	trace, err := tc.GetTrace(ctx, endpoint)
	if err != nil {
		trace = nil // Continue without trace history
	}

	result := &types.TraceAnalysisResult{
		TraceAvailable:    true,
		DetectedModel:     tc.convertToModelType(signature.DetectedWorkloadType),
		DetectedCategory:  tc.convertToModelCategory(signature.DetectedWorkloadType),
		DetectedFramework: tc.convertToFramework(signature.DetectedFramework),
		DetectedStage:     tc.convertToStage(signature.DetectedStage),
		DetectedIOPattern: tc.convertToIOPattern(signature.DetectedIOPattern),
		Confidence:        signature.Confidence,
		LastUpdated:       time.Now(),
	}
	if signature.ShardMetadata != nil {
		sm := signature.ShardMetadata
		result.ShardMetadata = &types.ShardMetadata{
			ShardPath:      sm.ShardPath,
			ShardSizeBytes: sm.ShardSizeBytes,
			ShardCount:     sm.ShardCount,
			ShardIndex:     sm.ShardIndex,
			ShardPaths:     append([]string(nil), sm.ShardPaths...),
			ShardEntries:   append([]string(nil), sm.ShardEntries...),
			ShardSource:    sm.ShardSource,
			ShardScanError: sm.ShardScanError,
			TarHeaderCount: sm.TarHeaderCount,
		}
	} else if signature.ShardPath != "" || signature.ShardCount > 0 {
		result.ShardMetadata = &types.ShardMetadata{
			ShardCount:     signature.ShardCount,
			ShardIndex:     signature.ShardIndex,
			ShardPath:      signature.ShardPath,
			ShardSizeBytes: signature.ShardSizeBytes,
		}
	}

	// Add metrics
	if metrics.CurrentMetrics != nil {
		result.AvgCPUUsage = metrics.CurrentMetrics.CPUUsagePercent
		result.AvgMemoryUsage = metrics.CurrentMetrics.MemoryUsagePercent
		result.AvgGPUUsage = metrics.CurrentMetrics.GPUUsagePercent
		result.AvgReadThroughput = metrics.CurrentMetrics.DiskReadBytesPerSec / (1024 * 1024)
		result.AvgWriteThroughput = metrics.CurrentMetrics.DiskWriteBytesPerSec / (1024 * 1024)
	}

	// Add trace ID and history
	if trace != nil {
		result.TraceID = trace.TraceID
		for _, sh := range trace.StageHistory {
			result.StageHistory = append(result.StageHistory, types.StageHistoryEntry{
				Stage:     tc.convertToStage(sh.Stage),
				StartTime: sh.StartTime,
				EndTime:   sh.EndTime,
				Duration:  sh.Duration,
			})
		}
	}

	return result, nil
}

// buildURL builds the full URL for an endpoint
func (tc *TraceClient) buildURL(baseEndpoint, path string) string {
	baseEndpoint = strings.TrimSuffix(baseEndpoint, "/")
	return baseEndpoint + path
}

// Conversion helpers
func (tc *TraceClient) convertToModelType(workloadType string) types.AIModelType {
	switch strings.ToLower(workloadType) {
	case "image", "vision":
		return types.ModelCNN // Generic vision model
	case "text", "nlp":
		return types.ModelTransformer // Generic NLP model
	case "audio":
		return types.ModelWhisper
	default:
		return types.ModelUnknown
	}
}

func (tc *TraceClient) convertToModelCategory(workloadType string) types.AIModelCategory {
	switch strings.ToLower(workloadType) {
	case "image", "vision":
		return types.ModelCategoryVision
	case "text", "nlp":
		return types.ModelCategoryNLP
	case "audio":
		return types.ModelCategoryAudio
	case "multimodal":
		return types.ModelCategoryMultimodal
	case "tabular":
		return types.ModelCategoryTabular
	default:
		return types.ModelCategoryUnknown
	}
}

func (tc *TraceClient) convertToFramework(framework string) types.AIFramework {
	switch strings.ToLower(framework) {
	case "pytorch", "torch":
		return types.FrameworkPyTorch
	case "tensorflow", "tf":
		return types.FrameworkTensorFlow
	case "jax":
		return types.FrameworkJAX
	case "huggingface", "transformers":
		return types.FrameworkHuggingFace
	case "onnx":
		return types.FrameworkONNX
	case "keras":
		return types.FrameworkKeras
	default:
		return types.FrameworkUnknown
	}
}

func (tc *TraceClient) convertToStage(stage string) types.PipelineStage {
	switch strings.ToLower(stage) {
	case "preprocessing", "preprocess":
		return types.StagePreprocesing
	case "training", "train":
		return types.StageTraining
	case "evaluation", "eval":
		return types.StageEvaluation
	case "inference", "infer":
		return types.StageInference
	case "serving", "serve":
		return types.StageServing
	case "finetuning", "finetune":
		return types.StageFineTuning
	default:
		return types.StageUnknown
	}
}

func (tc *TraceClient) convertToIOPattern(pattern string) types.IOPattern {
	switch strings.ToLower(pattern) {
	case "sequential_read":
		return types.IOPatternSequentialRead
	case "random_read":
		return types.IOPatternRandomRead
	case "burst_write":
		return types.IOPatternBurstWrite
	case "write_heavy":
		return types.IOPatternWriteHeavy
	case "distributed":
		return types.IOPatternDistributed
	default:
		return types.IOPatternBalanced
	}
}

// GetSidecarEndpoint returns the Insight Trace sidecar endpoint for a pod
// This can be called via pod IP or service
func GetSidecarEndpoint(podIP string, port int) string {
	if port == 0 {
		port = 9090 // Default sidecar port
	}
	return fmt.Sprintf("http://%s:%d", podIP, port)
}
