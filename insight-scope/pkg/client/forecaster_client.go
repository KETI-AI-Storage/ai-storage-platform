package client

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	hubpb "insight-hub/proto/hubpb"
	pb "insight-scope/proto/forecasterpb"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// ForecasterClient는 노드 히스토리 ingest를 Insight Hub로만 보내고,
// Forecast*/GetPeakIdle RPC는 Forecaster를 사용한다.
type ForecasterClient struct {
	hubEndpoint   string
	hubConn       *grpc.ClientConn
	hubClient     hubpb.InsightHubServiceClient

	forecastEndpoint string
	forecastConn     *grpc.ClientConn
	client           pb.NodeResourceForecasterServiceClient

	connected bool
	mu        sync.RWMutex

	historyBuffer map[string][]ResourceSnapshot
	bufferMu      sync.Mutex
	bufferSize    int
	flushInterval time.Duration
	stopChan      chan struct{}
}

// ResourceSnapshot represents a single resource utilization snapshot
type ResourceSnapshot struct {
	Timestamp         time.Time
	CPUUtilization    float64
	MemoryUtilization float64
	GPUUtilization    float64
	StorageIOUtil     float64
	// 비어 있으면 노드 집계; 둘 다 있으면 Pod 단위(Insight Hub에서 워크로드와 구분)
	PodNamespace string
	PodName      string
}

const bufKeySep = "\x1f"

func podBufferKey(nodeName, podNs, podName string) string {
	return nodeName + bufKeySep + podNs + bufKeySep + podName
}

func parseBufferKey(key string) (nodeName, podNs, podName string) {
	parts := strings.Split(key, bufKeySep)
	if len(parts) == 1 {
		return parts[0], "", ""
	}
	if len(parts) == 3 {
		return parts[0], parts[1], parts[2]
	}
	return key, "", ""
}

var (
	globalForecasterClient *ForecasterClient
	forecasterClientOnce   sync.Once
)

// GetForecasterClient returns the singleton Forecaster client
func GetForecasterClient() *ForecasterClient {
	forecasterClientOnce.Do(func() {
		fcEP := os.Getenv("FORECASTER_ENDPOINT")
		if fcEP == "" {
			fcEP = "node-resource-forecaster.apollo.svc.cluster.local:50055"
		}
		hubEP := os.Getenv("INSIGHT_HUB_ENDPOINT")

		globalForecasterClient = &ForecasterClient{
			hubEndpoint:      hubEP,
			forecastEndpoint: fcEP,
			historyBuffer:    make(map[string][]ResourceSnapshot),
			bufferSize:       60,
			flushInterval:    5 * time.Minute,
			stopChan:         make(chan struct{}),
		}

		go globalForecasterClient.backgroundFlush()

		go func() {
			if err := globalForecasterClient.Connect(); err != nil {
				log.Printf("[ForecasterClient] Initial connection failed: %v", err)
			}
		}()
	})
	return globalForecasterClient
}

func dial(ctx context.Context, addr string) (*grpc.ClientConn, error) {
	return grpc.DialContext(
		ctx,
		addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithBlock(),
	)
}

// Connect establishes gRPC connections (hub ingest + optional forecaster for forecasts).
func (c *ForecasterClient) Connect() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.connected {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if c.hubEndpoint != "" {
		log.Printf("[ForecasterClient] Connecting to Insight Hub (ingest): %s", c.hubEndpoint)
		hubConn, err := dial(ctx, c.hubEndpoint)
		if err != nil {
			return fmt.Errorf("insight hub: %w", err)
		}
		c.hubConn = hubConn
		c.hubClient = hubpb.NewInsightHubServiceClient(hubConn)
		log.Printf("[scope→hub] connected ingest endpoint=%s (metrics history will be sent here, not to Forecaster)", c.hubEndpoint)

		if err := c.connectForecastLocked(ctx); err != nil {
			log.Printf("[ForecasterClient] Forecaster unreachable (Forecast/PeakIdle will fail): %v", err)
		}
	} else {
		return fmt.Errorf("INSIGHT_HUB_ENDPOINT is required (metrics ingest must go to Insight Hub, not Forecaster SubmitHistoryData)")
	}

	c.connected = true
	return nil
}

func (c *ForecasterClient) connectForecastLocked(ctx context.Context) error {
	log.Printf("[ForecasterClient] Connecting to Forecaster (forecast RPCs): %s", c.forecastEndpoint)
	fcConn, err := dial(ctx, c.forecastEndpoint)
	if err != nil {
		return fmt.Errorf("forecaster: %w", err)
	}
	c.forecastConn = fcConn
	c.client = pb.NewNodeResourceForecasterServiceClient(fcConn)
	return nil
}

// Close closes connections
func (c *ForecasterClient) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	select {
	case <-c.stopChan:
	default:
		close(c.stopChan)
	}

	if c.hubConn != nil {
		_ = c.hubConn.Close()
		c.hubConn = nil
	}
	if c.forecastConn != nil {
		_ = c.forecastConn.Close()
		c.forecastConn = nil
	}
	c.connected = false
	c.hubClient = nil
	c.client = nil
	return nil
}

// IsConnected returns connection status
func (c *ForecasterClient) IsConnected() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.connected
}

// AddSnapshot adds a resource snapshot to the buffer (bufferKey = 노드명 또는 podBufferKey)
func (c *ForecasterClient) AddSnapshot(bufferKey string, snapshot ResourceSnapshot) {
	c.bufferMu.Lock()
	defer c.bufferMu.Unlock()

	c.historyBuffer[bufferKey] = append(c.historyBuffer[bufferKey], snapshot)

	if len(c.historyBuffer[bufferKey]) >= c.bufferSize {
		go c.flushBuffer(bufferKey)
	}
}

// AddNodeMetrics is a convenience method to add metrics
func (c *ForecasterClient) AddNodeMetrics(nodeName string, cpuUtil, memUtil, gpuUtil, storageIOUtil float64) {
	c.AddSnapshot(nodeName, ResourceSnapshot{
		Timestamp:         time.Now(),
		CPUUtilization:    cpuUtil,
		MemoryUtilization: memUtil,
		GPUUtilization:    gpuUtil,
		StorageIOUtil:     storageIOUtil,
	})
}

// AddPodMetrics sends per-pod utilization (metrics-server / requests) to Hub with pod identity.
func (c *ForecasterClient) AddPodMetrics(nodeName, podNs, podName string, cpuUtil, memUtil, gpuUtil, storageIOUtil float64) {
	if podNs == "" || podName == "" {
		return
	}
	key := podBufferKey(nodeName, podNs, podName)
	c.AddSnapshot(key, ResourceSnapshot{
		Timestamp:         time.Now(),
		CPUUtilization:    cpuUtil,
		MemoryUtilization: memUtil,
		GPUUtilization:    gpuUtil,
		StorageIOUtil:     storageIOUtil,
		PodNamespace:      podNs,
		PodName:           podName,
	})
}

func (c *ForecasterClient) flushBuffer(bufferKey string) {
	c.bufferMu.Lock()
	snapshots := c.historyBuffer[bufferKey]
	c.historyBuffer[bufferKey] = nil
	c.bufferMu.Unlock()

	if len(snapshots) == 0 {
		return
	}

	if !c.IsConnected() {
		if err := c.Connect(); err != nil {
			log.Printf("[ForecasterClient] Cannot flush, not connected: %v", err)
			c.bufferMu.Lock()
			c.historyBuffer[bufferKey] = append(snapshots, c.historyBuffer[bufferKey]...)
			c.bufferMu.Unlock()
			return
		}
	}

	if err := c.submitHistory(bufferKey, snapshots); err != nil {
		log.Printf("[ForecasterClient] Failed to submit history for %s: %v", bufferKey, err)
	} else {
		log.Printf("[ForecasterClient] Submitted %d snapshots for buffer %s", len(snapshots), bufferKey)
	}
}

func (c *ForecasterClient) submitHistory(bufferKey string, snapshots []ResourceSnapshot) error {
	nodeName, _, _ := parseBufferKey(bufferKey)
	c.mu.RLock()
	hub := c.hubClient
	c.mu.RUnlock()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if hub != nil {
		protoSnaps := make([]*hubpb.ResourceSnapshot, len(snapshots))
		for i, s := range snapshots {
			protoSnaps[i] = &hubpb.ResourceSnapshot{
				TimestampUnixMs:      s.Timestamp.UnixMilli(),
				CpuUtilization:       s.CPUUtilization,
				MemoryUtilization:    s.MemoryUtilization,
				GpuUtilization:       s.GPUUtilization,
				StorageIoUtilization: s.StorageIOUtil,
			}
			if s.PodNamespace != "" && s.PodName != "" {
				ns, pn := s.PodNamespace, s.PodName
				protoSnaps[i].PodNamespace = &ns
				protoSnaps[i].PodName = &pn
			}
		}
		req := &hubpb.SubmitHistoryRequest{NodeName: nodeName, Snapshots: protoSnaps}
		resp, err := hub.SubmitHistoryData(ctx, req)
		if err != nil {
			return fmt.Errorf("insight hub: %w", err)
		}
		if !resp.Accepted {
			return fmt.Errorf("insight hub rejected data")
		}
		log.Printf("[scope→hub] gRPC SubmitHistoryData ok node=%s sent_batch=%d hub_accepted_rows=%d",
			nodeName, len(snapshots), resp.SnapshotsProcessed)
		return nil
	}

	return fmt.Errorf("insight hub client unavailable (INSIGHT_HUB_ENDPOINT must be set and Connect must succeed before flush)")
}

func (c *ForecasterClient) backgroundFlush() {
	ticker := time.NewTicker(c.flushInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			c.FlushAll()
		case <-c.stopChan:
			return
		}
	}
}

// FlushAll flushes all buffered node data
func (c *ForecasterClient) FlushAll() {
	c.bufferMu.Lock()
	nodes := make([]string, 0, len(c.historyBuffer))
	for nodeName := range c.historyBuffer {
		if len(c.historyBuffer[nodeName]) > 0 {
			nodes = append(nodes, nodeName)
		}
	}
	c.bufferMu.Unlock()

	for _, k := range nodes {
		c.flushBuffer(k)
	}
}

// GetBufferStats returns current buffer statistics
func (c *ForecasterClient) GetBufferStats() map[string]int {
	c.bufferMu.Lock()
	defer c.bufferMu.Unlock()

	stats := make(map[string]int)
	for nodeName, snapshots := range c.historyBuffer {
		stats[nodeName] = len(snapshots)
	}
	return stats
}

// ForecastNode requests a forecast for a specific node
func (c *ForecasterClient) ForecastNode(nodeName string, horizons []int32) (*pb.ForecastNodeResponse, error) {
	c.mu.RLock()
	client := c.client
	c.mu.RUnlock()

	if client == nil {
		return nil, fmt.Errorf("client not initialized")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	req := &pb.ForecastNodeRequest{
		NodeName:                nodeName,
		ForecastHorizonsMinutes: horizons,
	}

	return client.ForecastNodeResources(ctx, req)
}

// GetPeakIdlePrediction requests peak/idle prediction
func (c *ForecasterClient) GetPeakIdlePrediction(nodeName string, lookaheadHours int32) (*pb.PeakIdleResponse, error) {
	c.mu.RLock()
	client := c.client
	c.mu.RUnlock()

	if client == nil {
		return nil, fmt.Errorf("client not initialized")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	req := &pb.PeakIdleRequest{
		NodeName:       nodeName,
		LookaheadHours: lookaheadHours,
	}

	return client.GetPeakIdlePrediction(ctx, req)
}
