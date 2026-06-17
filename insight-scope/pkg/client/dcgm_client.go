// ============================================
// DCGM Client for Insight Scope
// Fetches node-level GPU metrics from DCGM Exporter
// ============================================

package client

import (
	"context"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

// DCGMClient fetches GPU metrics from DCGM Exporter or metric-collector
type DCGMClient struct {
	httpClient     *http.Client

	// Endpoints for different nodes
	nodeEndpoints  map[string]string // nodeName -> endpoint URL
	endpointsMux   sync.RWMutex

	// Default endpoint (for single-node or service discovery)
	defaultEndpoint string

	// Cache
	metricsCache   map[string]*NodeGPUMetrics
	cacheMux       sync.RWMutex
	cacheTTL       time.Duration
}

// NodeGPUMetrics represents GPU metrics for a node
type NodeGPUMetrics struct {
	NodeName       string       `json:"node_name"`
	GPUs           []GPUMetrics `json:"gpus"`
	CollectedAt    time.Time    `json:"collected_at"`

	// Summary metrics
	TotalGPUs         int     `json:"total_gpus"`
	AverageUtilization float64 `json:"average_utilization"`
	TotalMemoryUsed   int64   `json:"total_memory_used_bytes"`
	TotalMemoryTotal  int64   `json:"total_memory_total_bytes"`
	HealthStatus      bool    `json:"health_status"`
	HasThermalIssue   bool    `json:"has_thermal_issue"`
	HasECCErrors      bool    `json:"has_ecc_errors"`
	HasPCIeBottleneck bool    `json:"has_pcie_bottleneck"`
}

// GPUMetrics represents metrics for a single GPU
type GPUMetrics struct {
	Index          string  `json:"index"`
	UUID           string  `json:"uuid"`
	Model          string  `json:"model"`
	Utilization    float64 `json:"utilization"`
	MemoryUsed     int64   `json:"memory_used_bytes"`
	MemoryTotal    int64   `json:"memory_total_bytes"`
	Temperature    float64 `json:"temperature"`
	PowerWatts     float64 `json:"power_watts"`
	SMClock        int64   `json:"sm_clock_mhz"`
	MemoryClock    int64   `json:"memory_clock_mhz"`
	PCIeTxBytes    int64   `json:"pcie_tx_bytes"`
	PCIeRxBytes    int64   `json:"pcie_rx_bytes"`
	NVLinkTxBytes  int64   `json:"nvlink_tx_bytes"`
	NVLinkRxBytes  int64   `json:"nvlink_rx_bytes"`
	ECCSingleBit   int64   `json:"ecc_single_bit_errors"`
	ECCDoubleBit   int64   `json:"ecc_double_bit_errors"`
}

// GPUHealthAnalysis provides analysis of GPU health and performance
type GPUHealthAnalysis struct {
	NodeName         string   `json:"node_name"`
	HealthStatus     string   `json:"health_status"` // healthy, warning, critical
	Issues           []string `json:"issues,omitempty"`
	Recommendations  []string `json:"recommendations,omitempty"`

	// Performance indicators
	AvgUtilization   float64  `json:"avg_utilization"`
	MemoryPressure   string   `json:"memory_pressure"` // low, medium, high
	ThermalStatus    string   `json:"thermal_status"`  // normal, elevated, critical
	PCIeStatus       string   `json:"pcie_status"`     // normal, congested

	// Capacity
	AvailableGPUs    int      `json:"available_gpus"`
	AvailableMemoryGB float64 `json:"available_memory_gb"`
}

// NewDCGMClient creates a new DCGM client
func NewDCGMClient() *DCGMClient {
	// Get default endpoint from env
	defaultEndpoint := os.Getenv("DCGM_ENDPOINT")
	if defaultEndpoint == "" {
		// Try metric-collector default endpoint (provides /gpu JSON API)
		defaultEndpoint = os.Getenv("METRIC_COLLECTOR_ENDPOINT")
	}
	if defaultEndpoint == "" {
		// Default: DCGM Exporter service directly
		defaultEndpoint = "http://dcgm-exporter.gpu-monitoring.svc.cluster.local:9400/metrics"
	}

	return &DCGMClient{
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
		nodeEndpoints:   make(map[string]string),
		defaultEndpoint: defaultEndpoint,
		metricsCache:    make(map[string]*NodeGPUMetrics),
		cacheTTL:        30 * time.Second,
	}
}

// SetNodeEndpoint sets the DCGM endpoint for a specific node
func (c *DCGMClient) SetNodeEndpoint(nodeName, endpoint string) {
	c.endpointsMux.Lock()
	defer c.endpointsMux.Unlock()
	c.nodeEndpoints[nodeName] = endpoint
}

// GetNodeGPUMetrics fetches GPU metrics for a specific node
func (c *DCGMClient) GetNodeGPUMetrics(ctx context.Context, nodeName string) (*NodeGPUMetrics, error) {
	// Check cache first
	c.cacheMux.RLock()
	if cached, exists := c.metricsCache[nodeName]; exists {
		if time.Since(cached.CollectedAt) < c.cacheTTL {
			c.cacheMux.RUnlock()
			return cached, nil
		}
	}
	c.cacheMux.RUnlock()

	// Get endpoint for node
	endpoint := c.getEndpointForNode(nodeName)

	// Fetch metrics
	req, err := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch DCGM metrics: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("DCGM endpoint returned status %d", resp.StatusCode)
	}

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	// Parse response (format from ai-storage-metric-collector /gpu endpoint)
	var rawResponse struct {
		GPUs []GPUMetrics `json:"gpus"`
	}
	if err := json.Unmarshal(body, &rawResponse); err != nil {
		return nil, fmt.Errorf("failed to parse metrics: %w", err)
	}

	// Build NodeGPUMetrics
	metrics := &NodeGPUMetrics{
		NodeName:    nodeName,
		GPUs:        rawResponse.GPUs,
		CollectedAt: time.Now(),
		TotalGPUs:   len(rawResponse.GPUs),
	}

	// Calculate summary metrics
	c.calculateSummary(metrics)

	// Update cache
	c.cacheMux.Lock()
	c.metricsCache[nodeName] = metrics
	c.cacheMux.Unlock()

	return metrics, nil
}

// calculateSummary calculates summary metrics for a node
func (c *DCGMClient) calculateSummary(metrics *NodeGPUMetrics) {
	if len(metrics.GPUs) == 0 {
		return
	}

	var totalUtil float64
	metrics.HealthStatus = true

	for _, gpu := range metrics.GPUs {
		totalUtil += gpu.Utilization
		metrics.TotalMemoryUsed += gpu.MemoryUsed
		metrics.TotalMemoryTotal += gpu.MemoryTotal

		// Check for thermal issues
		if gpu.Temperature > 85.0 {
			metrics.HasThermalIssue = true
			metrics.HealthStatus = false
		}

		// Check for ECC errors
		if gpu.ECCSingleBit > 0 || gpu.ECCDoubleBit > 0 {
			metrics.HasECCErrors = true
			metrics.HealthStatus = false
		}

		// Check for PCIe bottleneck (rough heuristic: >20GB/s sustained)
		pcieTotal := gpu.PCIeTxBytes + gpu.PCIeRxBytes
		if pcieTotal > 20*1024*1024*1024 {
			metrics.HasPCIeBottleneck = true
		}
	}

	metrics.AverageUtilization = totalUtil / float64(len(metrics.GPUs))
}

// AnalyzeNodeGPUHealth provides a health analysis for a node's GPUs
func (c *DCGMClient) AnalyzeNodeGPUHealth(ctx context.Context, nodeName string) (*GPUHealthAnalysis, error) {
	metrics, err := c.GetNodeGPUMetrics(ctx, nodeName)
	if err != nil {
		return nil, err
	}

	analysis := &GPUHealthAnalysis{
		NodeName:       nodeName,
		HealthStatus:   "healthy",
		AvgUtilization: metrics.AverageUtilization,
		AvailableGPUs:  metrics.TotalGPUs,
	}

	// Calculate available memory
	availableMem := float64(metrics.TotalMemoryTotal-metrics.TotalMemoryUsed) / (1024 * 1024 * 1024)
	analysis.AvailableMemoryGB = availableMem

	// Memory pressure analysis
	memUsagePercent := float64(metrics.TotalMemoryUsed) / float64(metrics.TotalMemoryTotal) * 100
	switch {
	case memUsagePercent < 50:
		analysis.MemoryPressure = "low"
	case memUsagePercent < 80:
		analysis.MemoryPressure = "medium"
	default:
		analysis.MemoryPressure = "high"
		analysis.Issues = append(analysis.Issues, "High GPU memory pressure")
		analysis.Recommendations = append(analysis.Recommendations, "Consider offloading workloads or using gradient checkpointing")
	}

	// Thermal analysis
	if metrics.HasThermalIssue {
		analysis.ThermalStatus = "critical"
		analysis.HealthStatus = "critical"
		analysis.Issues = append(analysis.Issues, "GPU temperature exceeds 85°C")
		analysis.Recommendations = append(analysis.Recommendations, "Check cooling system, reduce workload, or migrate pod")
	} else {
		analysis.ThermalStatus = "normal"
	}

	// PCIe analysis
	if metrics.HasPCIeBottleneck {
		analysis.PCIeStatus = "congested"
		if analysis.HealthStatus == "healthy" {
			analysis.HealthStatus = "warning"
		}
		analysis.Issues = append(analysis.Issues, "PCIe bandwidth saturation detected")
		analysis.Recommendations = append(analysis.Recommendations, "Consider NVLink for multi-GPU communication")
	} else {
		analysis.PCIeStatus = "normal"
	}

	// ECC errors
	if metrics.HasECCErrors {
		analysis.HealthStatus = "warning"
		analysis.Issues = append(analysis.Issues, "ECC memory errors detected")
		analysis.Recommendations = append(analysis.Recommendations, "Monitor GPU health, consider proactive replacement")
	}

	return analysis, nil
}

// GetClusterGPUSummary fetches GPU metrics for all known nodes
func (c *DCGMClient) GetClusterGPUSummary(ctx context.Context) (map[string]*NodeGPUMetrics, error) {
	c.endpointsMux.RLock()
	nodes := make([]string, 0, len(c.nodeEndpoints))
	for node := range c.nodeEndpoints {
		nodes = append(nodes, node)
	}
	c.endpointsMux.RUnlock()

	result := make(map[string]*NodeGPUMetrics)
	var wg sync.WaitGroup
	var mu sync.Mutex

	for _, node := range nodes {
		wg.Add(1)
		go func(nodeName string) {
			defer wg.Done()
			metrics, err := c.GetNodeGPUMetrics(ctx, nodeName)
			if err != nil {
				log.Printf("[DCGM] Failed to get metrics for node %s: %v", nodeName, err)
				return
			}
			mu.Lock()
			result[nodeName] = metrics
			mu.Unlock()
		}(node)
	}

	wg.Wait()
	return result, nil
}

// FindBestNodeForGPU finds the best node for a GPU workload
func (c *DCGMClient) FindBestNodeForGPU(ctx context.Context, requiredGPUs int, requiredMemoryGB float64) (string, error) {
	clusterMetrics, err := c.GetClusterGPUSummary(ctx)
	if err != nil {
		return "", err
	}

	var bestNode string
	var bestScore float64 = -1

	for nodeName, metrics := range clusterMetrics {
		// Skip unhealthy nodes
		if !metrics.HealthStatus {
			continue
		}

		// Check GPU count
		if metrics.TotalGPUs < requiredGPUs {
			continue
		}

		// Check memory availability
		availableMemGB := float64(metrics.TotalMemoryTotal-metrics.TotalMemoryUsed) / (1024 * 1024 * 1024)
		if availableMemGB < requiredMemoryGB {
			continue
		}

		// Score: prefer nodes with lower utilization and more headroom
		utilizationScore := 100 - metrics.AverageUtilization
		memoryScore := (availableMemGB / requiredMemoryGB) * 50
		thermalScore := 0.0
		if !metrics.HasThermalIssue {
			thermalScore = 20
		}

		score := utilizationScore + memoryScore + thermalScore

		if score > bestScore {
			bestScore = score
			bestNode = nodeName
		}
	}

	if bestNode == "" {
		return "", fmt.Errorf("no suitable node found for %d GPUs and %.1fGB memory", requiredGPUs, requiredMemoryGB)
	}

	return bestNode, nil
}

// getEndpointForNode returns the endpoint for a specific node
func (c *DCGMClient) getEndpointForNode(nodeName string) string {
	c.endpointsMux.RLock()
	defer c.endpointsMux.RUnlock()

	if endpoint, exists := c.nodeEndpoints[nodeName]; exists {
		return endpoint
	}
	return c.defaultEndpoint
}

// CombineWithTraceMetrics combines DCGM node metrics with pod-level trace metrics
func (c *DCGMClient) CombineWithTraceMetrics(nodeMetrics *NodeGPUMetrics, traceGPUUsage float64) *CombinedGPUAnalysis {
	analysis := &CombinedGPUAnalysis{
		NodeName:          nodeMetrics.NodeName,
		NodeGPUCount:      nodeMetrics.TotalGPUs,
		NodeAvgUtil:       nodeMetrics.AverageUtilization,
		NodeMemoryUsedGB:  float64(nodeMetrics.TotalMemoryUsed) / (1024 * 1024 * 1024),
		NodeMemoryTotalGB: float64(nodeMetrics.TotalMemoryTotal) / (1024 * 1024 * 1024),
		NodeHealthy:       nodeMetrics.HealthStatus,

		PodGPUUsage:       traceGPUUsage,
	}

	// Calculate pod's share of GPU resources
	if nodeMetrics.AverageUtilization > 0 {
		analysis.PodGPUShare = traceGPUUsage / nodeMetrics.AverageUtilization * 100
	}

	// Detect contention
	if nodeMetrics.AverageUtilization > 90 && traceGPUUsage < 50 {
		analysis.ContentionDetected = true
		analysis.ContentionReason = "Node GPU highly utilized but pod not fully using GPU - possible contention"
	}

	// Detect underutilization
	if nodeMetrics.AverageUtilization < 30 && traceGPUUsage < 30 {
		analysis.UnderutilizationDetected = true
		analysis.UnderutilizationReason = "Both node and pod GPU utilization low - consider GPU sharing or smaller instance"
	}

	return analysis
}

// CombinedGPUAnalysis represents combined analysis from DCGM and trace
type CombinedGPUAnalysis struct {
	// Node-level (from DCGM)
	NodeName          string  `json:"node_name"`
	NodeGPUCount      int     `json:"node_gpu_count"`
	NodeAvgUtil       float64 `json:"node_avg_utilization"`
	NodeMemoryUsedGB  float64 `json:"node_memory_used_gb"`
	NodeMemoryTotalGB float64 `json:"node_memory_total_gb"`
	NodeHealthy       bool    `json:"node_healthy"`

	// Pod-level (from insight-trace)
	PodGPUUsage       float64 `json:"pod_gpu_usage"`
	PodGPUShare       float64 `json:"pod_gpu_share_percent"` // Pod's share of node GPU

	// Analysis
	ContentionDetected     bool   `json:"contention_detected"`
	ContentionReason       string `json:"contention_reason,omitempty"`
	UnderutilizationDetected bool `json:"underutilization_detected"`
	UnderutilizationReason string `json:"underutilization_reason,omitempty"`
}
