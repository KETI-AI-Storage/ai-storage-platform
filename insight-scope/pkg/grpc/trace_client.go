package grpc

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	pb "insight-scope/proto/tracepb"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// TraceClient is a gRPC client for connecting to Insight Trace sidecars
type TraceClient struct {
	mu          sync.RWMutex
	connections map[string]*grpc.ClientConn
	clients     map[string]pb.InsightTraceServiceClient
	timeout     time.Duration
}

// NewTraceClient creates a new Insight Trace gRPC client
func NewTraceClient(timeout time.Duration) *TraceClient {
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	return &TraceClient{
		connections: make(map[string]*grpc.ClientConn),
		clients:     make(map[string]pb.InsightTraceServiceClient),
		timeout:     timeout,
	}
}

// getOrCreateClient gets existing client or creates new connection
func (c *TraceClient) getOrCreateClient(address string) (pb.InsightTraceServiceClient, error) {
	c.mu.RLock()
	if client, exists := c.clients[address]; exists {
		c.mu.RUnlock()
		return client, nil
	}
	c.mu.RUnlock()

	c.mu.Lock()
	defer c.mu.Unlock()

	// Double-check after acquiring write lock
	if client, exists := c.clients[address]; exists {
		return client, nil
	}

	// Create new connection
	conn, err := grpc.Dial(address,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to %s: %w", address, err)
	}

	client := pb.NewInsightTraceServiceClient(conn)
	c.connections[address] = conn
	c.clients[address] = client

	log.Printf("Connected to Insight Trace at %s", address)
	return client, nil
}

// GetMetrics retrieves current metrics from an Insight Trace sidecar
func (c *TraceClient) GetMetrics(ctx context.Context, address string) (*pb.MetricsResponse, error) {
	client, err := c.getOrCreateClient(address)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	return client.GetCurrentMetrics(ctx, &pb.GetMetricsRequest{})
}

// GetSignature retrieves workload signature from an Insight Trace sidecar
func (c *TraceClient) GetSignature(ctx context.Context, address string) (*pb.SignatureResponse, error) {
	client, err := c.getOrCreateClient(address)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	return client.GetSignature(ctx, &pb.GetSignatureRequest{})
}

// GetTrace retrieves full trace data from an Insight Trace sidecar
func (c *TraceClient) GetTrace(ctx context.Context, address string, includeHistory bool, maxHistoryCount int32) (*pb.TraceResponse, error) {
	client, err := c.getOrCreateClient(address)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	return client.GetTrace(ctx, &pb.GetTraceRequest{
		IncludeMetricsHistory: includeHistory,
		MaxHistoryCount:       maxHistoryCount,
	})
}

// GetStageHistory retrieves stage transition history from an Insight Trace sidecar
func (c *TraceClient) GetStageHistory(ctx context.Context, address string, limit int32) (*pb.StageHistoryResponse, error) {
	client, err := c.getOrCreateClient(address)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	return client.GetStageHistory(ctx, &pb.GetStageHistoryRequest{
		Limit: limit,
	})
}

// HealthCheck checks if an Insight Trace sidecar is healthy
func (c *TraceClient) HealthCheck(ctx context.Context, address string) (bool, error) {
	client, err := c.getOrCreateClient(address)
	if err != nil {
		return false, err
	}

	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	resp, err := client.HealthCheck(ctx, &pb.HealthCheckRequest{})
	if err != nil {
		return false, err
	}

	return resp.Healthy, nil
}

// StreamMetrics opens a stream to receive continuous metrics from Insight Trace
func (c *TraceClient) StreamMetrics(ctx context.Context, address string, intervalSeconds int32) (pb.InsightTraceService_StreamMetricsClient, error) {
	client, err := c.getOrCreateClient(address)
	if err != nil {
		return nil, err
	}

	return client.StreamMetrics(ctx, &pb.StreamMetricsRequest{
		IntervalSeconds: intervalSeconds,
	})
}

// StreamStageTransitions opens a stream to receive stage transition events
func (c *TraceClient) StreamStageTransitions(ctx context.Context, address string) (pb.InsightTraceService_StreamStageTransitionsClient, error) {
	client, err := c.getOrCreateClient(address)
	if err != nil {
		return nil, err
	}

	return client.StreamStageTransitions(ctx, &pb.StreamStageRequest{})
}

// Close closes all connections
func (c *TraceClient) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()

	for addr, conn := range c.connections {
		if err := conn.Close(); err != nil {
			log.Printf("Error closing connection to %s: %v", addr, err)
		}
	}

	c.connections = make(map[string]*grpc.ClientConn)
	c.clients = make(map[string]pb.InsightTraceServiceClient)
}

// RemoveConnection removes a specific connection (e.g., when pod is deleted)
func (c *TraceClient) RemoveConnection(address string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if conn, exists := c.connections[address]; exists {
		conn.Close()
		delete(c.connections, address)
		delete(c.clients, address)
		log.Printf("Removed connection to %s", address)
	}
}

// GetSidecarAddress returns the expected sidecar address for a pod
// In Kubernetes, sidecar is typically accessible via localhost within the pod
// or via pod IP from outside the pod
func GetSidecarAddress(podIP string, grpcPort string) string {
	if grpcPort == "" {
		grpcPort = "9091" // Default Insight Trace gRPC port
	}
	return fmt.Sprintf("%s:%s", podIP, grpcPort)
}
