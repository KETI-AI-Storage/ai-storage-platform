package grpcsvc

import (
	"context"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"insight-hub/internal/store"
	fpb "insight-hub/proto/forecasterbridgepb"
	"insight-hub/proto/hubpb"

	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

const version = "0.1.0"

// HubServer implements InsightHubService.
type HubServer struct {
	hubpb.UnimplementedInsightHubServiceServer
	st *store.Store
}

// NewHubServer creates the gRPC servicer.
func NewHubServer(st *store.Store) *HubServer {
	return &HubServer{st: st}
}

// SubmitHistoryData ingests batches from insight-scope.
func (s *HubServer) SubmitHistoryData(ctx context.Context, req *hubpb.SubmitHistoryRequest) (*hubpb.SubmitHistoryResponse, error) {
	node := req.GetNodeName()
	if node == "" {
		log.Printf("[hub.ingest] reject: empty node_name")
		return &hubpb.SubmitHistoryResponse{Accepted: false}, nil
	}
	snaps := req.GetSnapshots()
	n := len(snaps)
	if n == 0 {
		log.Printf("[hub.ingest] node=%s snapshots=0 (no-op)", node)
		return &hubpb.SubmitHistoryResponse{Accepted: true, SnapshotsProcessed: 0}, nil
	}

	rows := make([]store.SnapshotIn, n)
	for i, sn := range snaps {
		ts := sn.GetTimestampUnixMs()
		if ts == 0 {
			ts = time.Now().UnixMilli()
		}
		pns := sn.GetPodNamespace()
		pn := sn.GetPodName()
		rows[i] = store.SnapshotIn{
			TsUnixMs: ts,
			CPU:      sn.GetCpuUtilization(),
			Mem:      sn.GetMemoryUtilization(),
			GPU:      sn.GetGpuUtilization(),
			Sto:      sn.GetStorageIoUtilization(),
			PodNs:    pns,
			PodName:  pn,
		}
	}

	inserted, err := s.st.InsertSnapshots(ctx, node, rows)
	if err != nil {
		log.Printf("[hub.ingest] node=%s INSERT failed: %v", node, err)
		return &hubpb.SubmitHistoryResponse{Accepted: false}, err
	}
	var firstMs, lastMs int64
	if len(rows) > 0 {
		firstMs, lastMs = rows[0].TsUnixMs, rows[len(rows)-1].TsUnixMs
	}
	log.Printf("[hub.ingest] STORED sqlite node=%s batch_snapshots=%d rows_inserted=%d ts_ms_range=[%d,%d]",
		node, n, inserted, firstMs, lastMs)
	return &hubpb.SubmitHistoryResponse{Accepted: true, SnapshotsProcessed: int32(inserted)}, nil
}

// LegacyBridgeServer implements legacy forecaster SubmitHistoryData RPC.
type LegacyBridgeServer struct {
	fpb.UnimplementedNodeResourceForecasterServiceServer
	st *store.Store
}

func NewLegacyBridgeServer(st *store.Store) *LegacyBridgeServer {
	return &LegacyBridgeServer{st: st}
}

// SubmitHistoryData is a compatibility bridge for legacy insight-scope clients
// that still call apollo.forecaster.v1.NodeResourceForecasterService.
func (s *LegacyBridgeServer) SubmitHistoryData(ctx context.Context, req *fpb.SubmitHistoryRequest) (*fpb.SubmitHistoryResponse, error) {
	node := req.GetNodeName()
	if node == "" {
		log.Printf("[hub.ingest] reject(legacy): empty node_name")
		return &fpb.SubmitHistoryResponse{Accepted: false}, nil
	}
	snaps := req.GetSnapshots()
	n := len(snaps)
	if n == 0 {
		log.Printf("[hub.ingest] node=%s snapshots=0 (legacy no-op)", node)
		return &fpb.SubmitHistoryResponse{Accepted: true, SnapshotsProcessed: 0}, nil
	}

	rows := make([]store.SnapshotIn, n)
	for i, sn := range snaps {
		var ts int64
		if sn.GetTimestamp() != nil {
			ts = sn.GetTimestamp().AsTime().UnixMilli()
		}
		if ts == 0 {
			ts = time.Now().UnixMilli()
		}
		rows[i] = store.SnapshotIn{
			TsUnixMs: ts,
			CPU:      sn.GetCpuUtilization(),
			Mem:      sn.GetMemoryUtilization(),
			GPU:      sn.GetGpuUtilization(),
			Sto:      sn.GetStorageIoUtilization(),
		}
	}
	inserted, err := s.st.InsertSnapshots(ctx, node, rows)
	if err != nil {
		log.Printf("[hub.ingest] node=%s INSERT failed(legacy): %v", node, err)
		return &fpb.SubmitHistoryResponse{Accepted: false}, err
	}
	log.Printf("[hub.ingest] STORED sqlite(legacy-forecaster-rpc) node=%s batch_snapshots=%d rows_inserted=%d",
		node, n, inserted)
	return &fpb.SubmitHistoryResponse{Accepted: true, SnapshotsProcessed: int32(inserted)}, nil
}

// GetNodeHistory returns stored samples for forecaster consumers.
func (s *HubServer) GetNodeHistory(ctx context.Context, req *hubpb.GetNodeHistoryRequest) (*hubpb.GetNodeHistoryResponse, error) {
	node := req.GetNodeName()
	if node == "" {
		return &hubpb.GetNodeHistoryResponse{}, nil
	}
	since := req.GetSinceUnixMs()
	max := int(req.GetMaxSnapshots())
	rows, err := s.st.QueryNode(ctx, node, since, max)
	if err != nil {
		return nil, err
	}
	if os.Getenv("HUB_LOG_QUERIES") == "1" {
		log.Printf("[hub.query] GetNodeHistory node=%s since_unix_ms=%d max=%d returned=%d (sqlite read)",
			node, since, max, len(rows))
	}
	out := make([]*hubpb.ResourceSnapshot, 0, len(rows))
	for _, r := range rows {
		out = append(out, snapshotRowToProto(r, false))
	}
	return &hubpb.GetNodeHistoryResponse{Snapshots: out}, nil
}

func snapshotRowToProto(r store.SnapshotRow, includePod bool) *hubpb.ResourceSnapshot {
	s := &hubpb.ResourceSnapshot{
		TimestampUnixMs:      r.TsUnixMs,
		CpuUtilization:       r.CPU,
		MemoryUtilization:    r.Mem,
		GpuUtilization:       r.GPU,
		StorageIoUtilization: r.Sto,
	}
	if includePod && r.PodNs != "" && r.PodName != "" {
		ns, pn := r.PodNs, r.PodName
		s.PodNamespace = &ns
		s.PodName = &pn
	}
	return s
}

// GetPodHistory returns pod-scoped samples (workload-identified).
func (s *HubServer) GetPodHistory(ctx context.Context, req *hubpb.GetPodHistoryRequest) (*hubpb.GetPodHistoryResponse, error) {
	node := req.GetNodeName()
	ns := req.GetPodNamespace()
	pn := req.GetPodName()
	if node == "" || ns == "" || pn == "" {
		return &hubpb.GetPodHistoryResponse{}, nil
	}
	since := req.GetSinceUnixMs()
	max := int(req.GetMaxSnapshots())
	rows, err := s.st.QueryPod(ctx, node, ns, pn, since, max)
	if err != nil {
		return nil, err
	}
	out := make([]*hubpb.ResourceSnapshot, 0, len(rows))
	for _, r := range rows {
		out = append(out, snapshotRowToProto(r, true))
	}
	return &hubpb.GetPodHistoryResponse{Snapshots: out}, nil
}

// ListPods returns (node, namespace, name) keys that have pod-level rows.
func (s *HubServer) ListPods(ctx context.Context, _ *hubpb.ListPodsRequest) (*hubpb.ListPodsResponse, error) {
	keys, err := s.st.ListPods(ctx)
	if err != nil {
		return nil, err
	}
	pods := make([]*hubpb.PodKey, 0, len(keys))
	for _, k := range keys {
		pods = append(pods, &hubpb.PodKey{
			NodeName:      k.NodeName,
			PodNamespace:  k.PodNamespace,
			PodName:       k.PodName,
		})
	}
	return &hubpb.ListPodsResponse{Pods: pods}, nil
}

// ListNodes returns nodes that have at least one snapshot.
func (s *HubServer) ListNodes(ctx context.Context, _ *hubpb.ListNodesRequest) (*hubpb.ListNodesResponse, error) {
	names, err := s.st.ListNodes(ctx)
	if err != nil {
		return nil, err
	}
	if os.Getenv("HUB_LOG_QUERIES") == "1" {
		log.Printf("[hub.query] ListNodes count=%d (sqlite)", len(names))
	}
	return &hubpb.ListNodesResponse{NodeNames: names}, nil
}

// HealthCheck liveness.
func (s *HubServer) HealthCheck(ctx context.Context, _ *hubpb.HealthCheckRequest) (*hubpb.HealthCheckResponse, error) {
	var total int64
	if c, err := s.st.CountTotal(ctx); err == nil {
		total = c
	}
	return &hubpb.HealthCheckResponse{Healthy: true, Version: version, TotalSnapshots: total}, nil
}

// Serve listens on addr (e.g. :50056) and blocks until error.
func Serve(addr string, st *store.Store) (*grpc.Server, error) {
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	srv := grpc.NewServer()
	hubpb.RegisterInsightHubServiceServer(srv, NewHubServer(st))
	fpb.RegisterNodeResourceForecasterServiceServer(srv, NewLegacyBridgeServer(st))
	reflection.Register(srv)
	go func() {
		log.Printf("[hub] gRPC listening on %s", addr)
		if err := srv.Serve(lis); err != nil {
			log.Printf("[hub] gRPC serve: %v", err)
		}
	}()
	return srv, nil
}

// StartPruneLoop deletes rows older than retention periodically.
func StartPruneLoop(st *store.Store, stop <-chan struct{}) {
	days := store.RetentionDays()
	ticker := time.NewTicker(1 * time.Hour)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				cutoff := time.Now().UTC().AddDate(0, 0, -days)
				n, err := st.PruneOlderThan(context.Background(), cutoff)
				if err != nil {
					log.Printf("[hub] prune: %v", err)
				} else if n > 0 {
					log.Printf("[hub] pruned %d snapshots older than %v", n, cutoff)
				}
			}
		}
	}()
}

// ListenAddr from env GRPC_PORT / default.
func ListenAddr() string {
	p := os.Getenv("GRPC_PORT")
	if p == "" {
		p = "50056"
	}
	if p[0] == ':' {
		return p
	}
	return ":" + p
}

// OrchestrationResultPayload는 오케스트레이션 결과 수집 HTTP 페이로드이다.
type OrchestrationResultPayload struct {
	PolicyName     string                 `json:"policy_name"`
	TargetWorkload string                 `json:"target_workload"`
	Namespace      string                 `json:"namespace"`
	Node           string                 `json:"node"`
	Action         string                 `json:"action"`
	Result         string                 `json:"result"`
	TimestampUnixMs int64                 `json:"timestamp_unix_ms"`
	BeforeState    map[string]interface{} `json:"before_state,omitempty"`
	AfterState     map[string]interface{} `json:"after_state,omitempty"`
	Metadata       map[string]interface{} `json:"metadata,omitempty"`
}

// OrchestrationResultIngestHandler는 정책 실행 결과를 SQLite로 저장한다.
func OrchestrationResultIngestHandler(st *store.Store) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/orchestration-results", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		defer r.Body.Close()

		var req OrchestrationResultPayload
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid json payload", http.StatusBadRequest)
			return
		}
		if req.PolicyName == "" || req.TargetWorkload == "" || req.Namespace == "" || req.Action == "" || req.Result == "" {
			http.Error(w, "missing required fields", http.StatusBadRequest)
			return
		}
		if req.Node == "" {
			req.Node = "unknown"
		}
		if req.TimestampUnixMs == 0 {
			req.TimestampUnixMs = time.Now().UnixMilli()
		}

		if err := st.InsertOrchestrationResult(r.Context(), store.OrchestrationResultIn{
			PolicyName:     req.PolicyName,
			TargetWorkload: req.TargetWorkload,
			Namespace:      req.Namespace,
			Node:           req.Node,
			Action:         req.Action,
			Result:         req.Result,
			TsUnixMs:       req.TimestampUnixMs,
			BeforeState:    req.BeforeState,
			AfterState:     req.AfterState,
			Metadata:       req.Metadata,
		}); err != nil {
			log.Printf("[hub.orch] insert failed: %v", err)
			http.Error(w, "failed to persist orchestration result", http.StatusInternalServerError)
			return
		}

		log.Printf("[hub.orch] stored policy=%s workload=%s namespace=%s node=%s action=%s result=%s ts=%d",
			req.PolicyName, req.TargetWorkload, req.Namespace, req.Node, req.Action, req.Result, req.TimestampUnixMs)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"accepted":true}`))
	})
	return mux
}
