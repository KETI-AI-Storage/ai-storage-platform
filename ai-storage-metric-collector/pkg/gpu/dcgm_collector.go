// ============================================
// DCGM GPU Metrics Collector
// Node-level GPU metrics from DCGM Exporter
// ============================================

package gpu

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// DCGMCollector collects GPU metrics from DCGM Exporter
type DCGMCollector struct {
	dcgmEndpoint string
	httpClient   *http.Client

	// Current metrics
	metrics    map[string]*GPUMetrics
	metricsMux sync.RWMutex

	// Prometheus gauges
	gpuUtilization    *prometheus.GaugeVec
	gpuMemoryUsed     *prometheus.GaugeVec
	gpuMemoryTotal    *prometheus.GaugeVec
	gpuTemperature    *prometheus.GaugeVec
	gpuPowerUsage     *prometheus.GaugeVec
	gpuSMClock        *prometheus.GaugeVec
	gpuMemoryClock    *prometheus.GaugeVec
	gpuPCIeTxBytes    *prometheus.GaugeVec
	gpuPCIeRxBytes    *prometheus.GaugeVec
	gpuNVLinkTxBytes  *prometheus.GaugeVec
	gpuNVLinkRxBytes  *prometheus.GaugeVec
	gpuECCErrors      *prometheus.GaugeVec

	// Collection status
	lastCollectTime time.Time
	collectErrors   int64
}

// GPUMetrics holds metrics for a single GPU
type GPUMetrics struct {
	UUID            string
	DeviceIndex     string
	ModelName       string

	// Utilization
	GPUUtilization  float64 // DCGM_FI_DEV_GPU_UTIL
	MemoryUtilization float64 // DCGM_FI_DEV_MEM_COPY_UTIL

	// Memory
	MemoryUsedBytes  int64   // DCGM_FI_DEV_FB_USED
	MemoryTotalBytes int64   // DCGM_FI_DEV_FB_TOTAL

	// Thermal & Power
	Temperature     float64 // DCGM_FI_DEV_GPU_TEMP
	PowerUsage      float64 // DCGM_FI_DEV_POWER_USAGE

	// Clocks
	SMClock         int64   // DCGM_FI_DEV_SM_CLOCK
	MemoryClock     int64   // DCGM_FI_DEV_MEM_CLOCK

	// PCIe
	PCIeTxBytes     int64   // DCGM_FI_DEV_PCIE_TX_THROUGHPUT
	PCIeRxBytes     int64   // DCGM_FI_DEV_PCIE_RX_THROUGHPUT

	// NVLink
	NVLinkTxBytes   int64   // DCGM_FI_DEV_NVLINK_BANDWIDTH_TX_TOTAL
	NVLinkRxBytes   int64   // DCGM_FI_DEV_NVLINK_BANDWIDTH_RX_TOTAL

	// Errors
	ECCSingleBitErrors int64 // DCGM_FI_DEV_ECC_SBE_VOL_TOTAL
	ECCDoubleBitErrors int64 // DCGM_FI_DEV_ECC_DBE_VOL_TOTAL

	// Timestamp
	LastUpdated time.Time
}

// NewDCGMCollector creates a new DCGM collector
func NewDCGMCollector() *DCGMCollector {
	// Get DCGM exporter endpoint from env, default to dcgm-exporter service
	endpoint := os.Getenv("DCGM_EXPORTER_ENDPOINT")
	if endpoint == "" {
		// Default: DCGM Exporter service in gpu-monitoring namespace
		endpoint = "http://dcgm-exporter.gpu-monitoring.svc.cluster.local:9400/metrics"
	}

	collector := &DCGMCollector{
		dcgmEndpoint: endpoint,
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
		metrics: make(map[string]*GPUMetrics),
	}

	// Initialize Prometheus gauges
	collector.initPrometheusMetrics()

	return collector
}

// initPrometheusMetrics initializes Prometheus gauge vectors
func (c *DCGMCollector) initPrometheusMetrics() {
	labels := []string{"gpu", "uuid", "modelName"}

	c.gpuUtilization = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_utilization",
		Help: "GPU utilization (0-100%)",
	}, labels)

	c.gpuMemoryUsed = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_memory_used_bytes",
		Help: "GPU memory used in bytes",
	}, labels)

	c.gpuMemoryTotal = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_memory_total_bytes",
		Help: "GPU total memory in bytes",
	}, labels)

	c.gpuTemperature = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_temperature_celsius",
		Help: "GPU temperature in Celsius",
	}, labels)

	c.gpuPowerUsage = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_power_usage_watts",
		Help: "GPU power usage in watts",
	}, labels)

	c.gpuSMClock = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_sm_clock_mhz",
		Help: "GPU SM clock in MHz",
	}, labels)

	c.gpuMemoryClock = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_memory_clock_mhz",
		Help: "GPU memory clock in MHz",
	}, labels)

	c.gpuPCIeTxBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_pcie_tx_bytes",
		Help: "GPU PCIe TX throughput in bytes/sec",
	}, labels)

	c.gpuPCIeRxBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_pcie_rx_bytes",
		Help: "GPU PCIe RX throughput in bytes/sec",
	}, labels)

	c.gpuNVLinkTxBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_nvlink_tx_bytes",
		Help: "GPU NVLink TX throughput in bytes/sec",
	}, labels)

	c.gpuNVLinkRxBytes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_nvlink_rx_bytes",
		Help: "GPU NVLink RX throughput in bytes/sec",
	}, labels)

	c.gpuECCErrors = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "dcgm_gpu_ecc_errors_total",
		Help: "GPU ECC errors total",
	}, append(labels, "error_type"))

	// Register all metrics
	prometheus.MustRegister(c.gpuUtilization)
	prometheus.MustRegister(c.gpuMemoryUsed)
	prometheus.MustRegister(c.gpuMemoryTotal)
	prometheus.MustRegister(c.gpuTemperature)
	prometheus.MustRegister(c.gpuPowerUsage)
	prometheus.MustRegister(c.gpuSMClock)
	prometheus.MustRegister(c.gpuMemoryClock)
	prometheus.MustRegister(c.gpuPCIeTxBytes)
	prometheus.MustRegister(c.gpuPCIeRxBytes)
	prometheus.MustRegister(c.gpuNVLinkTxBytes)
	prometheus.MustRegister(c.gpuNVLinkRxBytes)
	prometheus.MustRegister(c.gpuECCErrors)
}

// Collect fetches metrics from DCGM Exporter
func (c *DCGMCollector) Collect() error {
	resp, err := c.httpClient.Get(c.dcgmEndpoint)
	if err != nil {
		c.collectErrors++
		return fmt.Errorf("failed to fetch DCGM metrics: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		c.collectErrors++
		return fmt.Errorf("DCGM exporter returned status %d", resp.StatusCode)
	}

	// Parse Prometheus text format
	if err := c.parsePrometheusMetrics(resp.Body); err != nil {
		c.collectErrors++
		return fmt.Errorf("failed to parse metrics: %w", err)
	}

	c.lastCollectTime = time.Now()
	log.Printf("[DCGM] Collected metrics for %d GPUs", len(c.metrics))

	return nil
}

// parsePrometheusMetrics parses DCGM metrics from Prometheus text format
func (c *DCGMCollector) parsePrometheusMetrics(r io.Reader) error {
	c.metricsMux.Lock()
	defer c.metricsMux.Unlock()

	scanner := bufio.NewScanner(r)

	for scanner.Scan() {
		line := scanner.Text()

		// Skip comments and empty lines
		if strings.HasPrefix(line, "#") || line == "" {
			continue
		}

		// Parse metric line: metric_name{labels} value
		if !strings.HasPrefix(line, "DCGM_") {
			continue
		}

		metricName, labels, value := c.parseMetricLine(line)
		if metricName == "" {
			continue
		}

		// Extract GPU identifier
		gpuIndex := labels["gpu"]
		uuid := labels["UUID"]
		modelName := labels["modelName"]

		if gpuIndex == "" {
			continue
		}

		// Get or create GPU metrics
		gpu, exists := c.metrics[gpuIndex]
		if !exists {
			gpu = &GPUMetrics{
				DeviceIndex: gpuIndex,
				UUID:        uuid,
				ModelName:   modelName,
			}
			c.metrics[gpuIndex] = gpu
		}

		gpu.LastUpdated = time.Now()

		// Update metrics based on name
		switch metricName {
		case "DCGM_FI_DEV_GPU_UTIL":
			gpu.GPUUtilization = value
			c.gpuUtilization.WithLabelValues(gpuIndex, uuid, modelName).Set(value)

		case "DCGM_FI_DEV_MEM_COPY_UTIL":
			gpu.MemoryUtilization = value

		case "DCGM_FI_DEV_FB_USED":
			gpu.MemoryUsedBytes = int64(value * 1024 * 1024) // MiB to bytes
			c.gpuMemoryUsed.WithLabelValues(gpuIndex, uuid, modelName).Set(float64(gpu.MemoryUsedBytes))

		case "DCGM_FI_DEV_FB_TOTAL":
			gpu.MemoryTotalBytes = int64(value * 1024 * 1024)
			c.gpuMemoryTotal.WithLabelValues(gpuIndex, uuid, modelName).Set(float64(gpu.MemoryTotalBytes))

		case "DCGM_FI_DEV_GPU_TEMP":
			gpu.Temperature = value
			c.gpuTemperature.WithLabelValues(gpuIndex, uuid, modelName).Set(value)

		case "DCGM_FI_DEV_POWER_USAGE":
			gpu.PowerUsage = value
			c.gpuPowerUsage.WithLabelValues(gpuIndex, uuid, modelName).Set(value)

		case "DCGM_FI_DEV_SM_CLOCK":
			gpu.SMClock = int64(value)
			c.gpuSMClock.WithLabelValues(gpuIndex, uuid, modelName).Set(value)

		case "DCGM_FI_DEV_MEM_CLOCK":
			gpu.MemoryClock = int64(value)
			c.gpuMemoryClock.WithLabelValues(gpuIndex, uuid, modelName).Set(value)

		case "DCGM_FI_DEV_PCIE_TX_THROUGHPUT":
			gpu.PCIeTxBytes = int64(value)
			c.gpuPCIeTxBytes.WithLabelValues(gpuIndex, uuid, modelName).Set(value)

		case "DCGM_FI_DEV_PCIE_RX_THROUGHPUT":
			gpu.PCIeRxBytes = int64(value)
			c.gpuPCIeRxBytes.WithLabelValues(gpuIndex, uuid, modelName).Set(value)

		case "DCGM_FI_DEV_NVLINK_BANDWIDTH_TX_TOTAL":
			gpu.NVLinkTxBytes = int64(value)
			c.gpuNVLinkTxBytes.WithLabelValues(gpuIndex, uuid, modelName).Set(value)

		case "DCGM_FI_DEV_NVLINK_BANDWIDTH_RX_TOTAL":
			gpu.NVLinkRxBytes = int64(value)
			c.gpuNVLinkRxBytes.WithLabelValues(gpuIndex, uuid, modelName).Set(value)

		case "DCGM_FI_DEV_ECC_SBE_VOL_TOTAL":
			gpu.ECCSingleBitErrors = int64(value)
			c.gpuECCErrors.WithLabelValues(gpuIndex, uuid, modelName, "single_bit").Set(value)

		case "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL":
			gpu.ECCDoubleBitErrors = int64(value)
			c.gpuECCErrors.WithLabelValues(gpuIndex, uuid, modelName, "double_bit").Set(value)
		}
	}

	return scanner.Err()
}

// parseMetricLine parses a Prometheus metric line
func (c *DCGMCollector) parseMetricLine(line string) (string, map[string]string, float64) {
	labels := make(map[string]string)

	// Find the position of labels
	labelStart := strings.Index(line, "{")
	labelEnd := strings.Index(line, "}")

	if labelStart == -1 || labelEnd == -1 {
		// No labels, just metric_name value
		parts := strings.Fields(line)
		if len(parts) >= 2 {
			val, _ := strconv.ParseFloat(parts[1], 64)
			return parts[0], labels, val
		}
		return "", labels, 0
	}

	metricName := line[:labelStart]
	labelStr := line[labelStart+1 : labelEnd]
	valueStr := strings.TrimSpace(line[labelEnd+1:])

	// Parse labels
	for _, pair := range strings.Split(labelStr, ",") {
		kv := strings.SplitN(pair, "=", 2)
		if len(kv) == 2 {
			key := strings.TrimSpace(kv[0])
			value := strings.Trim(strings.TrimSpace(kv[1]), "\"")
			labels[key] = value
		}
	}

	// Parse value
	value, _ := strconv.ParseFloat(valueStr, 64)

	return metricName, labels, value
}

// GetMetrics returns all GPU metrics
func (c *DCGMCollector) GetMetrics() map[string]*GPUMetrics {
	c.metricsMux.RLock()
	defer c.metricsMux.RUnlock()

	result := make(map[string]*GPUMetrics)
	for k, v := range c.metrics {
		result[k] = v
	}
	return result
}

// GetGPUCount returns the number of GPUs
func (c *DCGMCollector) GetGPUCount() int {
	c.metricsMux.RLock()
	defer c.metricsMux.RUnlock()
	return len(c.metrics)
}

// GetTotalGPUMemoryUsed returns total GPU memory used across all GPUs
func (c *DCGMCollector) GetTotalGPUMemoryUsed() int64 {
	c.metricsMux.RLock()
	defer c.metricsMux.RUnlock()

	var total int64
	for _, gpu := range c.metrics {
		total += gpu.MemoryUsedBytes
	}
	return total
}

// GetAverageGPUUtilization returns average GPU utilization
func (c *DCGMCollector) GetAverageGPUUtilization() float64 {
	c.metricsMux.RLock()
	defer c.metricsMux.RUnlock()

	if len(c.metrics) == 0 {
		return 0
	}

	var total float64
	for _, gpu := range c.metrics {
		total += gpu.GPUUtilization
	}
	return total / float64(len(c.metrics))
}

// HasPCIeBottleneck checks if any GPU has PCIe bottleneck
func (c *DCGMCollector) HasPCIeBottleneck(threshold int64) bool {
	c.metricsMux.RLock()
	defer c.metricsMux.RUnlock()

	for _, gpu := range c.metrics {
		// PCIe Gen4 x16 theoretical max: ~32GB/s
		// If both TX and RX are near max, there might be bottleneck
		if gpu.PCIeTxBytes > threshold || gpu.PCIeRxBytes > threshold {
			return true
		}
	}
	return false
}

// HasThermalIssue checks if any GPU is overheating
func (c *DCGMCollector) HasThermalIssue(threshold float64) bool {
	c.metricsMux.RLock()
	defer c.metricsMux.RUnlock()

	for _, gpu := range c.metrics {
		if gpu.Temperature > threshold {
			return true
		}
	}
	return false
}

// HasECCErrors checks if any GPU has ECC errors
func (c *DCGMCollector) HasECCErrors() bool {
	c.metricsMux.RLock()
	defer c.metricsMux.RUnlock()

	for _, gpu := range c.metrics {
		if gpu.ECCSingleBitErrors > 0 || gpu.ECCDoubleBitErrors > 0 {
			return true
		}
	}
	return false
}
