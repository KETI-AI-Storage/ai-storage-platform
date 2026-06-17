package collector

import (
	"bufio"
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"insight-scope/pkg/client"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsv1beta1 "k8s.io/metrics/pkg/client/clientset/versioned"
)

// MetricsCollector collects node resource metrics and sends to Forecaster
type MetricsCollector struct {
	k8sClient     kubernetes.Interface
	metricsClient *metricsv1beta1.Clientset
	nodeName      string

	forecasterClient *client.ForecasterClient
	collectInterval  time.Duration
	stopChan         chan struct{}
	wg               sync.WaitGroup

	// disk I/O tracking (prev sample for rate calculation)
	prevDiskReadBytes  uint64
	prevDiskWriteBytes uint64
	prevDiskSampleTime time.Time

	dcgmEndpoint string
	httpClient   *http.Client
}

// NewMetricsCollector creates a new metrics collector
func NewMetricsCollector(kubeconfig string) (*MetricsCollector, error) {
	var config *rest.Config
	var err error

	if kubeconfig != "" {
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
	} else {
		config, err = rest.InClusterConfig()
	}
	if err != nil {
		return nil, err
	}

	k8sClient, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, err
	}

	metricsClient, err := metricsv1beta1.NewForConfig(config)
	if err != nil {
		log.Printf("[MetricsCollector] Warning: metrics client creation failed: %v", err)
		// Continue without metrics client, will use simulated values
	}

	// Get node name from environment (set by Kubernetes)
	nodeName := os.Getenv("NODE_NAME")
	if nodeName == "" {
		nodeName = os.Getenv("HOSTNAME")
	}

	dcgmEndpoint := os.Getenv("DCGM_EXPORTER_ENDPOINT")
	if dcgmEndpoint == "" {
		dcgmEndpoint = "http://dcgm-exporter.gpu-monitoring.svc.cluster.local:9400/metrics"
	}

	return &MetricsCollector{
		k8sClient:        k8sClient,
		metricsClient:    metricsClient,
		nodeName:         nodeName,
		forecasterClient: client.GetForecasterClient(),
		collectInterval:  1 * time.Minute,
		stopChan:         make(chan struct{}),
		dcgmEndpoint:     dcgmEndpoint,
		httpClient:       &http.Client{Timeout: 5 * time.Second},
	}, nil
}

// Start begins the metrics collection loop
func (mc *MetricsCollector) Start() {
	mc.wg.Add(1)
	go mc.collectLoop()
	log.Printf("[MetricsCollector] Started collecting metrics for node %s every %v", mc.nodeName, mc.collectInterval)
}

// Stop stops the metrics collector
func (mc *MetricsCollector) Stop() {
	close(mc.stopChan)
	mc.wg.Wait()
	log.Printf("[MetricsCollector] Stopped")
}

// collectLoop periodically collects and sends metrics
func (mc *MetricsCollector) collectLoop() {
	defer mc.wg.Done()

	ticker := time.NewTicker(mc.collectInterval)
	defer ticker.Stop()

	// Initial collection
	mc.collectAndSend()

	for {
		select {
		case <-ticker.C:
			mc.collectAndSend()
		case <-mc.stopChan:
			return
		}
	}
}

// collectAndSend collects metrics and sends to Forecaster
func (mc *MetricsCollector) collectAndSend() {
	if mc.nodeName == "" {
		log.Printf("[MetricsCollector] Node name not set, skipping collection")
		return
	}

	cpuUtil, memUtil, gpuUtil, storageIOUtil := mc.collectNodeMetrics()

	mc.forecasterClient.AddNodeMetrics(
		mc.nodeName,
		cpuUtil,
		memUtil,
		gpuUtil,
		storageIOUtil,
	)
	// Pod 단위(라벨 선택) → Hub에 ns/name 으로 저장 (노드 집계와 분리)
	if os.Getenv("INSIGHT_HUB_ENDPOINT") != "" {
		sel := os.Getenv("POD_METRICS_LABEL_SELECTOR")
		if sel != "" {
			mc.collectPodMetricsForHub()
		}
	}
	// Optional: prove per-minute sampling (set HUB_TRACE_METRICS=1 on insight-scope pod)
	if os.Getenv("HUB_TRACE_METRICS") == "1" {
		log.Printf("[scope-metrics] node=%s sampled 1 snapshot → buffer (next hub flush: 5m timer or 60 snapshots)", mc.nodeName)
	}
}

// collectPodMetricsForHub lists pods on this node matching POD_METRICS_LABEL_SELECTOR,
// reads metrics-server PodMetrics, computes usage/request ratios, and sends to Hub with pod identity.
func (mc *MetricsCollector) collectPodMetricsForHub() {
	if mc.metricsClient == nil {
		return
	}
	sel := os.Getenv("POD_METRICS_LABEL_SELECTOR")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	pods, err := mc.k8sClient.CoreV1().Pods("").List(ctx, metav1.ListOptions{
		FieldSelector: "spec.nodeName=" + mc.nodeName,
		LabelSelector: sel,
	})
	if err != nil {
		log.Printf("[MetricsCollector] list pods on node for pod metrics: %v", err)
		return
	}
	for i := range pods.Items {
		pod := &pods.Items[i]
		pm, err := mc.metricsClient.MetricsV1beta1().PodMetricses(pod.Namespace).Get(ctx, pod.Name, metav1.GetOptions{})
		if err != nil {
			continue
		}
		cpuU, memU := podUtilizationFromMetrics(pm, pod)
		mc.forecasterClient.AddPodMetrics(mc.nodeName, pod.Namespace, pod.Name, cpuU, memU, 0, 0)
		if os.Getenv("HUB_TRACE_METRICS") == "1" {
			log.Printf("[scope-metrics] pod sample ns=%s name=%s cpu=%.4f mem=%.4f → hub buffer", pod.Namespace, pod.Name, cpuU, memU)
		}
	}
}

func podUtilizationFromMetrics(pm *metricsapi.PodMetrics, pod *corev1.Pod) (cpuUtil, memUtil float64) {
	var useCPU int64
	for _, c := range pm.Containers {
		if c.Usage.Cpu() != nil {
			useCPU += c.Usage.Cpu().MilliValue()
		}
	}
	var reqCPU int64
	for _, c := range pod.Spec.Containers {
		if q := c.Resources.Requests.Cpu(); q != nil {
			reqCPU += q.MilliValue()
		}
	}
	if reqCPU == 0 {
		for _, c := range pod.Spec.Containers {
			if q := c.Resources.Limits.Cpu(); q != nil {
				reqCPU += q.MilliValue()
			}
		}
	}
	if reqCPU > 0 {
		cpuUtil = float64(useCPU) / float64(reqCPU)
		if cpuUtil > 1.0 {
			cpuUtil = 1.0
		}
	}

	var useMem int64
	for _, c := range pm.Containers {
		if c.Usage.Memory() != nil {
			useMem += c.Usage.Memory().Value()
		}
	}
	var reqMem int64
	for _, c := range pod.Spec.Containers {
		if q := c.Resources.Requests.Memory(); q != nil {
			reqMem += q.Value()
		}
	}
	if reqMem == 0 {
		for _, c := range pod.Spec.Containers {
			if q := c.Resources.Limits.Memory(); q != nil {
				reqMem += q.Value()
			}
		}
	}
	if reqMem > 0 {
		memUtil = float64(useMem) / float64(reqMem)
		if memUtil > 1.0 {
			memUtil = 1.0
		}
	}
	return
}

// collectNodeMetrics collects resource utilization from the node
func (mc *MetricsCollector) collectNodeMetrics() (cpuUtil, memUtil, gpuUtil, storageIOUtil float64) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Try to get node metrics from metrics-server
	if mc.metricsClient != nil {
		nodeMetrics, err := mc.metricsClient.MetricsV1beta1().NodeMetricses().Get(ctx, mc.nodeName, metav1.GetOptions{})
		if err == nil {
			// Get node capacity for utilization calculation
			node, err := mc.k8sClient.CoreV1().Nodes().Get(ctx, mc.nodeName, metav1.GetOptions{})
			if err == nil {
				// Calculate CPU utilization
				cpuUsage := nodeMetrics.Usage.Cpu().MilliValue()
				cpuCapacity := node.Status.Capacity.Cpu().MilliValue()
				if cpuCapacity > 0 {
					cpuUtil = float64(cpuUsage) / float64(cpuCapacity)
				}

				// Calculate Memory utilization
				memUsage := nodeMetrics.Usage.Memory().Value()
				memCapacity := node.Status.Capacity.Memory().Value()
				if memCapacity > 0 {
					memUtil = float64(memUsage) / float64(memCapacity)
				}

				log.Printf("[MetricsCollector] Node %s: CPU=%.2f%%, Memory=%.2f%%",
					mc.nodeName, cpuUtil*100, memUtil*100)
			}
		} else {
			log.Printf("[MetricsCollector] Failed to get node metrics: %v, using simulated values", err)
			cpuUtil, memUtil = mc.simulateMetrics()
		}
	} else {
		cpuUtil, memUtil = mc.simulateMetrics()
	}

	// GPU utilization (would need DCGM or nvidia-smi integration)
	gpuUtil = mc.collectGPUMetrics()

	// Storage I/O utilization (would need iostat or similar)
	storageIOUtil = mc.collectStorageIOMetrics()

	return
}

// simulateMetrics returns simulated metrics for testing
func (mc *MetricsCollector) simulateMetrics() (cpuUtil, memUtil float64) {
	// Generate somewhat realistic fluctuating values
	hour := float64(time.Now().Hour())

	// Simulate higher usage during work hours (9-18)
	if hour >= 9 && hour <= 18 {
		cpuUtil = 0.4 + (hour-9)/20.0   // 40-80%
		memUtil = 0.5 + (hour-9)/30.0   // 50-80%
	} else {
		cpuUtil = 0.2 + (hour)/50.0     // 20-50%
		memUtil = 0.3 + (hour)/50.0     // 30-60%
	}

	return
}

// collectGPUMetrics scrapes DCGM Exporter (Prometheus format) for this node's GPU utilization.
// Returns average utilization across all GPUs on the node as a fraction [0.0, 1.0].
// Returns 0.0 gracefully when DCGM is not available (non-GPU nodes).
func (mc *MetricsCollector) collectGPUMetrics() float64 {
	resp, err := mc.httpClient.Get(mc.dcgmEndpoint)
	if err != nil {
		// DCGM not deployed or not reachable — non-GPU node, silently return 0
		return 0.0
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Printf("[MetricsCollector] DCGM exporter returned HTTP %d", resp.StatusCode)
		return 0.0
	}

	// DCGM exports per-GPU lines; collect all utilization values and average them.
	// Example line: DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="...",node="worker-1",...} 72
	var total float64
	var count int

	nodeFilter := fmt.Sprintf(`node="%s"`, mc.nodeName)
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "#") || line == "" {
			continue
		}
		if !strings.HasPrefix(line, "DCGM_FI_DEV_GPU_UTIL") {
			continue
		}
		// Only count metrics that belong to this node (if label is present)
		if mc.nodeName != "" && !strings.Contains(line, nodeFilter) && strings.Contains(line, `node="`) {
			continue
		}
		// Value is the last field after the closing brace
		parts := strings.Fields(line)
		if len(parts) < 2 {
			continue
		}
		val, err := strconv.ParseFloat(parts[len(parts)-1], 64)
		if err != nil {
			continue
		}
		total += val
		count++
	}

	if count == 0 {
		return 0.0
	}
	// DCGM reports utilization as 0–100; convert to 0.0–1.0
	return (total / float64(count)) / 100.0
}

// collectStorageIOMetrics reads /proc/diskstats to calculate the node-level disk I/O
// utilization as a fraction [0.0, 1.0] relative to a configurable saturation threshold.
// Uses delta between two samples to get a rate over the collection interval.
func (mc *MetricsCollector) collectStorageIOMetrics() float64 {
	const diskstatsPath = "/proc/diskstats"
	// Sector size is 512 bytes on all Linux block devices
	const sectorBytes = 512
	// Treat this many MB/s of combined read+write as "100% utilization" (tunable via env)
	saturationMBps := 500.0
	if v := os.Getenv("STORAGE_SATURATION_MBPS"); v != "" {
		if parsed, err := strconv.ParseFloat(v, 64); err == nil && parsed > 0 {
			saturationMBps = parsed
		}
	}

	data, err := os.ReadFile(diskstatsPath)
	if err != nil {
		log.Printf("[MetricsCollector] Cannot read %s: %v", diskstatsPath, err)
		return 0.0
	}

	var readSectors, writeSectors uint64
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		// diskstats fields: major minor name reads_completed ... sectors_read ... sectors_written ...
		// field[0]=major [1]=minor [2]=name [3]=reads [4]=reads_merged [5]=sectors_read
		// [6]=read_ms [7]=writes [8]=writes_merged [9]=sectors_written
		if len(fields) < 10 {
			continue
		}
		name := fields[2]
		// Skip loop devices, ram disks, and partitions (only aggregate whole disks)
		if strings.HasPrefix(name, "loop") || strings.HasPrefix(name, "ram") {
			continue
		}
		// Skip partitions: sda1, nvme0n1p1, etc.
		if len(name) > 0 && (name[len(name)-1] >= '0' && name[len(name)-1] <= '9') &&
			(strings.Contains(name, "sd") || strings.Contains(name, "hd")) {
			continue
		}
		r, _ := strconv.ParseUint(fields[5], 10, 64)
		w, _ := strconv.ParseUint(fields[9], 10, 64)
		readSectors += r
		writeSectors += w
	}

	now := time.Now()
	totalBytes := (readSectors + writeSectors) * sectorBytes

	if mc.prevDiskSampleTime.IsZero() {
		// First sample — store baseline and return 0 (no delta yet)
		mc.prevDiskReadBytes = readSectors * sectorBytes
		mc.prevDiskWriteBytes = writeSectors * sectorBytes
		mc.prevDiskSampleTime = now
		return 0.0
	}

	elapsed := now.Sub(mc.prevDiskSampleTime).Seconds()
	if elapsed <= 0 {
		return 0.0
	}

	prevTotal := mc.prevDiskReadBytes + mc.prevDiskWriteBytes
	deltaMBps := float64(totalBytes-prevTotal) / elapsed / (1024 * 1024)

	// Update previous sample
	mc.prevDiskReadBytes = readSectors * sectorBytes
	mc.prevDiskWriteBytes = writeSectors * sectorBytes
	mc.prevDiskSampleTime = now

	util := deltaMBps / saturationMBps
	if util > 1.0 {
		util = 1.0
	}
	log.Printf("[MetricsCollector] Node %s: StorageIO=%.1f MB/s (util=%.2f%%)",
		mc.nodeName, deltaMBps, util*100)
	return util
}

