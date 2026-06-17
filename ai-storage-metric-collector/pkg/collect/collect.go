package collect

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/shirou/gopsutil/cpu"
	"github.com/shirou/gopsutil/disk"
	"github.com/shirou/gopsutil/mem"

	"keti/ai-storage-metric-collector/pkg/gpu"
	metric "keti/ai-storage-metric-collector/pkg/proto"

	"k8s.io/client-go/kubernetes"
)

// Prometheus Gauge 선언
var (
	cpuUsage = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "node_cpu_usage_percent",
		Help: "CPU usage percent (전체 평균)",
	})
	memUsage = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "node_memory_usage_percent",
		Help: "Memory usage percent (전체 메모리)",
	})
	diskUsage = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "node_disk_usage_percent",
		Help: "Disk usage percent (root 마운트)",
	})

	// GPU summary metrics (from DCGM)
	gpuCount = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "node_gpu_count",
		Help: "Number of GPUs on this node",
	})
	gpuAvgUtilization = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "node_gpu_avg_utilization_percent",
		Help: "Average GPU utilization across all GPUs",
	})
	gpuTotalMemoryUsed = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "node_gpu_total_memory_used_bytes",
		Help: "Total GPU memory used across all GPUs",
	})
	gpuHealthStatus = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "node_gpu_health_status",
		Help: "GPU health status (1=healthy, 0=issue detected)",
	})
)

type MetricCollector struct {
	HostKubeClient *kubernetes.Clientset
	Interval       *time.Duration
	ClusterMetric  metric.MultiMetric

	// DCGM GPU collector
	dcgmCollector  *gpu.DCGMCollector
	dcgmEnabled    bool
}

func NewMetricCollector() *MetricCollector {
	// Prometheus 메트릭 등록
	prometheus.MustRegister(cpuUsage)
	prometheus.MustRegister(memUsage)
	prometheus.MustRegister(diskUsage)
	prometheus.MustRegister(gpuCount)
	prometheus.MustRegister(gpuAvgUtilization)
	prometheus.MustRegister(gpuTotalMemoryUsed)
	prometheus.MustRegister(gpuHealthStatus)

	// Check if DCGM is enabled
	dcgmEnabled := os.Getenv("DCGM_ENABLED") != "false"

	var dcgmCollector *gpu.DCGMCollector
	if dcgmEnabled {
		dcgmCollector = gpu.NewDCGMCollector()
		log.Println("[metric-collector] DCGM GPU collector enabled")
	}

	return &MetricCollector{
		HostKubeClient: nil,
		Interval:       nil,
		ClusterMetric:  metric.MultiMetric{},
		dcgmCollector:  dcgmCollector,
		dcgmEnabled:    dcgmEnabled,
	}
}

// 자원 측정 및 Gauge 기록 goroutine
func (m *MetricCollector) recordMetrics(ctx context.Context) {
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				// CPU 사용률
				percent, err := cpu.Percent(0, false)
				if err == nil && len(percent) > 0 {
					cpuUsage.Set(percent[0])
				}
				// 메모리 사용률
				vmStat, err := mem.VirtualMemory()
				if err == nil {
					memUsage.Set(vmStat.UsedPercent)
				}
				// 디스크 사용률
				diskStat, err := disk.Usage("/")
				if err == nil {
					diskUsage.Set(diskStat.UsedPercent)
				}

				// GPU 메트릭 (DCGM)
				if m.dcgmEnabled && m.dcgmCollector != nil {
					if err := m.dcgmCollector.Collect(); err != nil {
						log.Printf("[DCGM] Collection error: %v", err)
					} else {
						// Update summary metrics
						gpuCount.Set(float64(m.dcgmCollector.GetGPUCount()))
						gpuAvgUtilization.Set(m.dcgmCollector.GetAverageGPUUtilization())
						gpuTotalMemoryUsed.Set(float64(m.dcgmCollector.GetTotalGPUMemoryUsed()))

						// Health check
						health := 1.0
						if m.dcgmCollector.HasThermalIssue(85.0) {
							health = 0
							log.Printf("[DCGM] WARNING: GPU thermal issue detected (>85°C)")
						}
						if m.dcgmCollector.HasECCErrors() {
							health = 0
							log.Printf("[DCGM] WARNING: GPU ECC errors detected")
						}
						gpuHealthStatus.Set(health)
					}
				}
			}
		}
	}()
}

// 핸들러: promhttp.Handler 사용
func MetricsHandler() http.Handler {
	return promhttp.Handler()
}

// GPUMetricsHandler returns current GPU metrics as JSON
func (m *MetricCollector) GPUMetricsHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !m.dcgmEnabled || m.dcgmCollector == nil {
			http.Error(w, "DCGM not enabled", http.StatusServiceUnavailable)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		metrics := m.dcgmCollector.GetMetrics()

		// Simple JSON response
		w.Write([]byte("{\"gpus\": ["))
		first := true
		for idx, gpu := range metrics {
			if !first {
				w.Write([]byte(","))
			}
			first = false
			w.Write([]byte(`{"index":"` + idx + `",`))
			w.Write([]byte(`"uuid":"` + gpu.UUID + `",`))
			w.Write([]byte(`"model":"` + gpu.ModelName + `",`))
			w.Write([]byte(`"utilization":` + formatFloat(gpu.GPUUtilization) + `,`))
			w.Write([]byte(`"memory_used_bytes":` + formatInt(gpu.MemoryUsedBytes) + `,`))
			w.Write([]byte(`"memory_total_bytes":` + formatInt(gpu.MemoryTotalBytes) + `,`))
			w.Write([]byte(`"temperature":` + formatFloat(gpu.Temperature) + `,`))
			w.Write([]byte(`"power_watts":` + formatFloat(gpu.PowerUsage) + `,`))
			w.Write([]byte(`"pcie_tx_bytes":` + formatInt(gpu.PCIeTxBytes) + `,`))
			w.Write([]byte(`"pcie_rx_bytes":` + formatInt(gpu.PCIeRxBytes) + `}`))
		}
		w.Write([]byte("]}"))
	}
}

func formatFloat(f float64) string {
	return fmt.Sprintf("%.2f", f)
}

func formatInt(i int64) string {
	return fmt.Sprintf("%d", i)
}

// 서버 실행부에서 MetricsHandler 사용
func (m *MetricCollector) RunMetricCollector(ctx context.Context, wg *sync.WaitGroup) {
	defer wg.Done()

	// 값 주기적 측정
	m.recordMetrics(ctx)

	mux := http.NewServeMux()
	mux.Handle("/metrics", MetricsHandler())
	mux.HandleFunc("/gpu", m.GPUMetricsHandler())

	srv := &http.Server{
		Addr:    ":2112",
		Handler: mux,
	}

	go func() {
		<-ctx.Done()
		log.Println("Shutting down metrics server...")
		srv.Shutdown(context.Background())
	}()

	log.Println("[metric-collector] start /metrics server at :2112")
	log.Println("[metric-collector] GPU metrics available at /gpu")
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatalf("ListenAndServe: %v", err)
	}
}
