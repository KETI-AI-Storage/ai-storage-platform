package scheduler

import (
	"bufio"
	"context"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	logger "keti/ai-storage-scheduler/internal/backend/log"
	internalqueue "keti/ai-storage-scheduler/internal/backend/queue"
	config "keti/ai-storage-scheduler/internal/config"
	framework "keti/ai-storage-scheduler/internal/framework"
	utils "keti/ai-storage-scheduler/internal/framework/utils"
	"sync"

	"k8s.io/apimachinery/pkg/util/wait"
)

var MainScheduler *Scheduler

var ErrNoNodesAvailable = fmt.Errorf("no nodes available to schedule pods")

type Scheduler struct {
	schedulerConfig *config.SchedulerConfig
	Cache           *utils.Cache
	NextPod         func() (*internalqueue.QueuedPodInfo, error)
	StopEverything  <-chan struct{}
	SchedulingQueue *internalqueue.SchedulingQueue
	fwk             framework.Framework
	logger          *logger.Logger
}

type ScheduleResult struct {
	SuggestedHost   string          // Name of the selected node.
	FeasibleNodes   int             // The number of nodes out of the evaluated ones that fit the pod.
	nominatingInfo  *NominatingInfo // The nominating info for scheduling cycle.
	PluginResultMap utils.PluginResultMap
	PolicyRequestID string          // APOLLO policy request ID for feedback
}

func NewScheduleResult(nodeInfoMap map[string]*utils.NodeInfo) ScheduleResult {
	pluginResultMap := make(utils.PluginResultMap, len(nodeInfoMap))

	for nodeName, nodeInfo := range nodeInfoMap {
		gpuScores := make(map[string]*utils.GPUScore)

		if nodeInfo != nil && nodeInfo.GPUMap != nil {
			for gpuID := range nodeInfo.GPUMap {
				gpuScores[gpuID] = &utils.GPUScore{}
			}
		}

		pluginResultMap[nodeName] = utils.PluginResult{
			GPUScores:      gpuScores,
			IsFiltered:     false,
			Scores:         make([]utils.PluginScore, 0),
			TotalNodeScore: 0,
		}
	}

	return ScheduleResult{
		SuggestedHost:   "",
		FeasibleNodes:   0,
		nominatingInfo:  nil,
		PluginResultMap: utils.PluginResultMap{},
	}
}

type NominatingMode int

const (
	ModeNoop NominatingMode = iota
	ModeOverride
)

type NominatingInfo struct {
	NominatedNodeName string
	NominatingMode    NominatingMode
}

func NewScheduler(ctx context.Context, cc *config.SchedulerConfig) (*Scheduler, error) {
	stopEverything := ctx.Done()
	schedulerCache := cc.Cache
	podQueue := internalqueue.NewSchedulingQueue(internalqueue.Less, cc.InformerFactory)
	logger := logger.NewLogger(logger.NewDefaultConfig())

	// Initialize framework with plugins
	fwk := cc.Framework
	if fwk == nil {
		return nil, fmt.Errorf("framework is required")
	}

	sched := &Scheduler{
		schedulerConfig: cc,
		Cache:           schedulerCache,
		StopEverything:  stopEverything,
		SchedulingQueue: podQueue,
		fwk:             fwk,
		logger:          logger,
	}

	if err := AddAllEventHandlers(sched, cc.InformerFactory); err != nil {
		return nil, fmt.Errorf("adding event handlers: %w", err)
	}

	sched.NextPod = podQueue.Pop

	return sched, nil
}

func (sched *Scheduler) InitScheduler() error {
	sched.schedulerConfig.InformerFactory.WaitForCacheSync(sched.StopEverything)

	return nil
}

func (sched *Scheduler) Run(ctx context.Context) {
	var internalWG sync.WaitGroup

	internalWG.Add(1)
	go func() {
		defer internalWG.Done()
		sched.schedulerConfig.InformerFactory.Start(ctx.Done())
	}()

	internalWG.Add(1)
	go func() {
		defer internalWG.Done()
		sched.SchedulingQueue.Run()
	}()

	internalWG.Add(1)
	go func() {
		defer internalWG.Done()
		wait.UntilWithContext(ctx, sched.ScheduleOne, 0)
	}()

	// GPU metrics worker
	internalWG.Add(1)
	go func() {
		defer internalWG.Done()
		sched.gpuMetricsWorker(ctx)
	}()

	<-ctx.Done()
	sched.SchedulingQueue.Close()

	internalWG.Wait()
	logger.Info("All scheduler workers stopped")
}

// GPU Metrics Collection Functions

// dcgmEndpoint returns the DCGM Exporter scrape URL.
// Configurable via DCGM_EXPORTER_ENDPOINT env variable.
func dcgmEndpoint() string {
	if ep := os.Getenv("DCGM_EXPORTER_ENDPOINT"); ep != "" {
		return ep
	}
	return "http://dcgm-exporter.gpu-monitoring.svc.cluster.local:9400/metrics"
}

// fetchNodeGPUMetrics scrapes the DCGM Exporter and updates the cache with live
// GPU utilization/memory for the given node. Non-GPU nodes return silently.
func (sched *Scheduler) fetchNodeGPUMetrics(nodeName string) {
	logger.Info("[gpu-metrics] Fetching GPU metrics for node", "node", nodeName)

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(dcgmEndpoint())
	if err != nil {
		// DCGM not deployed — skip silently (non-GPU cluster)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		logger.Info("[gpu-metrics] DCGM returned non-200", "status", resp.StatusCode)
		return
	}

	// gpu UUID → GPUInfo accumulator
	gpuMap := make(map[string]utils.GPUInfo)

	nodeFilter := fmt.Sprintf(`node="%s"`, nodeName)
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "#") || line == "" {
			continue
		}
		// Only process metrics that belong to this node
		if nodeName != "" && strings.Contains(line, `node="`) && !strings.Contains(line, nodeFilter) {
			continue
		}

		// Extract GPU UUID label
		uuid := extractDCGMLabel(line, "UUID")
		if uuid == "" {
			uuid = extractDCGMLabel(line, "uuid")
		}
		if uuid == "" {
			// Use gpu index as fallback key
			uuid = "gpu-" + extractDCGMLabel(line, "gpu")
		}

		entry := gpuMap[uuid]
		entry.UUID = uuid

		parts := strings.Fields(line)
		if len(parts) < 2 {
			continue
		}
		val, err := strconv.ParseFloat(parts[len(parts)-1], 64)
		if err != nil {
			continue
		}

		switch {
		case strings.HasPrefix(line, "DCGM_FI_DEV_GPU_UTIL"):
			entry.UtilizationPct = val
		case strings.HasPrefix(line, "DCGM_FI_DEV_FB_USED"):
			entry.MemoryUsedMB = int64(val)
		case strings.HasPrefix(line, "DCGM_FI_DEV_FB_TOTAL"):
			entry.MemoryTotalMB = int64(val)
		case strings.HasPrefix(line, "DCGM_FI_DEV_GPU_TEMP"):
			entry.TemperatureCelsius = val
		case strings.HasPrefix(line, "DCGM_FI_DEV_POWER_USAGE"):
			entry.PowerWatts = val
		}
		gpuMap[uuid] = entry
	}

	if err := sched.Cache.UpdateNodeGPUMetrics(nodeName, gpuMap); err != nil {
		logger.Info("[gpu-metrics] Cache update failed", "node", nodeName, "err", err)
		return
	}
	logger.Info("[gpu-metrics] Updated GPU metrics", "node", nodeName, "gpus", len(gpuMap))
}

// extractDCGMLabel parses a Prometheus label value from a DCGM metric line.
// e.g. extractDCGMLabel(`DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-abc",...} 72`, "UUID") → "GPU-abc"
func extractDCGMLabel(line, key string) string {
	prefix := key + `="`
	idx := strings.Index(line, prefix)
	if idx == -1 {
		return ""
	}
	start := idx + len(prefix)
	end := strings.Index(line[start:], `"`)
	if end == -1 {
		return ""
	}
	return line[start : start+end]
}

// refreshStaleGPUMetrics refreshes GPU metrics for nodes where metrics are older than maxAge
func (sched *Scheduler) refreshStaleGPUMetrics(ctx context.Context, maxAge int64) {
	nodes := sched.Cache.Nodes()
	currentTime := utils.GetCurrentTimeMillis()

	for nodeName, nodeInfo := range nodes {
		if nodeInfo == nil {
			continue
		}

		// Check if GPU metrics are stale
		metricsAge := currentTime - nodeInfo.GPUMetricsUpdatedAt.UnixMilli()
		if metricsAge > maxAge {
			logger.Info("[gpu-metrics] Refreshing stale GPU metrics", "node", nodeName, "age_ms", metricsAge)
			sched.fetchNodeGPUMetrics(nodeName)
		}
	}
}

// refreshAllGPUMetrics refreshes GPU metrics for all nodes
func (sched *Scheduler) refreshAllGPUMetrics() {
	logger.Info("[gpu-metrics] Refreshing GPU metrics for all nodes")

	nodes := sched.Cache.Nodes()
	for nodeName := range nodes {
		sched.fetchNodeGPUMetrics(nodeName)
	}
}

// gpuMetricsWorker periodically refreshes GPU metrics for all nodes
func (sched *Scheduler) gpuMetricsWorker(ctx context.Context) {
	logger.Info("[gpu-metrics] Starting GPU metrics worker")

	// Initial collection
	sched.refreshAllGPUMetrics()

	// Periodic refresh every 5 minutes
	wait.UntilWithContext(ctx, func(ctx context.Context) {
		sched.refreshAllGPUMetrics()
	}, 300000000000) // 5 minutes in nanoseconds

	logger.Info("[gpu-metrics] GPU metrics worker stopped")
}
