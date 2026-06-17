# ARCHITECTURE.md

This file documents the architecture and conventions of this repository.

## Project Overview

This is the **KETI AI Storage System** - a research-based Kubernetes infrastructure for AI workload optimization using Computational Storage Devices (CSD). The system consists of four main Go-based components that work together to provide intelligent pod scheduling, resource orchestration, and performance monitoring.

**Core Innovation**: Integration of CSD (Computational Storage Device) resources into Kubernetes scheduling decisions, plus optimized pod migration that reduces CPU usage by 50% and memory by 40% by excluding completed containers during migration.

## System Architecture

The workspace contains 4 primary Go components that form a complete AI storage orchestration system:

### 1. **ai-storage-scheduler** (Custom Kubernetes Scheduler)
- **Purpose**: Custom K8s scheduler that considers CSD and GPU resources when placing pods
- **Key Feature**: Plugin-based architecture with Filter, Score, and Bind phases
- **Scheduling Logic**: NodeResourcesFit (filter) → LeastAllocated (score, partially implemented) → DefaultBinder (bind)
- **GPU Support**: Infrastructure ready (metrics worker, stale refresh logic, data structures) but gRPC integration is TODO
- **Entry Point**: `cmd/main.go`
- **Namespace**: Deployed to `keti` namespace

### 2. **ai-storage-orchestrator** (Pod Migration Controller)
- **Purpose**: Research-based pod migration that optimizes resource usage by analyzing container states
- **Key Innovation**: Only migrates running/failed containers, excludes completed ones (50% CPU, 40% memory reduction)
- **Migration Pipeline**: Capture states → Create PVC checkpoint → Create optimized pod → Delete original
- **API**: RESTful HTTP API (Gin framework) on port 8080
- **Entry Point**: `cmd/main.go`
- **Namespace**: Deployed to `kube-system` namespace
- **Note**: Has comprehensive ARCHITECTURE.md already written

### 3. **ai-storage-metric-collector** (Metrics Collection)
- **Purpose**: Collects node and pod metrics for the scheduler
- **Entry Point**: `cmd/main.go`
- **Architecture**: Long-running goroutine with graceful shutdown

### 4. **ai-storage-api-server** (API Gateway)
- **Purpose**: API server for AI Storage orchestration
- **Status**: Documentation incomplete, needs investigation
- **Entry Point**: `cmd/main.go`

## Building and Deploying

### General Pattern
All four components follow a similar build pattern:

```bash
# Build binary (from component directory)
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o bin/component-name cmd/main.go

# Build Docker image (from component directory)
docker build -t component-name:latest .

# Deploy to Kubernetes
kubectl apply -f deployments/component.yaml
```

### Component-Specific Build Commands

#### AI Storage Scheduler
```bash
cd ai-storage-scheduler

# Build and push image
./scripts/1.build-image.sh
# Builds binary → Docker image → Tags as ketidevit2/keti-ai-storage-scheduler:latest → Pushes

# Deploy to K8s
./scripts/2.apply-deployment.sh apply    # or: ./scripts/2.apply-deployment.sh a
./scripts/2.apply-deployment.sh delete   # or: ./scripts/2.apply-deployment.sh d

# View logs
./scripts/3.trace-log.sh

# Manual deployment
kubectl apply -f deployments/ai-storage-scheduler.yaml
kubectl get pods -n keti -l app=ai-storage-scheduler

# Test with GPU pod
kubectl apply -f deployments/test-gpu-pod.yaml
```

#### AI Storage Orchestrator
```bash
cd ai-storage-orchestrator

# Build and deploy
./scripts/build.sh [tag]   # default: latest
./scripts/deploy.sh [tag]

# Test APIs
kubectl port-forward -n kube-system svc/ai-storage-orchestrator 8080:8080
curl http://localhost:8080/health

# View logs
kubectl logs -n kube-system -l app=ai-storage-orchestrator -f

# Run tests
go test ./pkg/...
```

#### AI Storage Metric Collector
```bash
cd ai-storage-metric-collector

# Build binary
go build -o bin/metric-collector cmd/main.go

# Build and deploy using scripts (check scripts/ directory)
./scripts/build.sh
./scripts/deploy.sh
```

#### AI Storage API Server
```bash
cd ai-storage-api-server

# Build and deploy using scripts (check scripts/ directory)
./scripts/build.sh
./scripts/deploy.sh
```

### Prerequisites for All Components
- **Kubernetes**: 1.25+
- **Go**: 1.21+
- **Docker**: Latest version
- **kubectl**: Cluster access configured
- **Container Runtime**: containerd (images imported to k8s.io namespace)

## Kubernetes Node Labeling

The system requires specific node labels for proper scheduling:

```bash
# Control Plane / Master Node
kubectl label nodes ai-storage-master layer=orchestration
kubectl label nodes ai-storage-master node-role.kubernetes.io/control-plane=

# Compute Nodes (Worker nodes with compute capability)
kubectl label nodes <worker-node> layer=compute
kubectl label nodes <worker-node> node-role.kubernetes.io/worker=

# Storage Nodes (Nodes with CSD devices)
kubectl label nodes <storage-node> layer=storage
kubectl label nodes <storage-node> node-role.kubernetes.io/worker=
```

## Key Implementation Details

### Scheduler Architecture (ai-storage-scheduler)

**Scheduling Flow**:
1. Pod Informer detects unscheduled pods with `schedulerName: "ai-storage-scheduler"`
2. Pod enters SchedulingQueue (priority queue with heap)
3. `ScheduleOne()` processes pod through scheduling cycle:
   - If pod requests GPU: `refreshStaleGPUMetrics()` for metrics >60s old
   - `schedulePod()`: Filter unsuitable nodes → Score remaining nodes → Select best
   - `assume()`: Optimistically update cache before actual binding
4. `bindingCycle()`: Asynchronously bind pod to node via Kubernetes API
5. Background `gpuMetricsWorker()`: Refreshes all GPU metrics every 5 minutes

**Plugin System** (in `internal/framework/plugin/`):
- **NodeResourcesFit** (Filter): Checks CPU/Memory availability
- **LeastAllocated** (Score): Returns 0 currently - scoring logic exists in `scoreNode()` helper but not integrated
- **DefaultBinder** (Bind): Creates Binding resource via K8s API

**Important**: GPU scheduling infrastructure is ready (data structures, workers, refresh logic) but actual gRPC calls to fetch GPU metrics are TODO (see `scheduler.go:157`).

### Orchestrator Migration Pipeline (ai-storage-orchestrator)

**Container State Analysis** (`pkg/k8s/client.go`):
- **waiting**: `ShouldMigrate = false` - not yet started
- **running**: `ShouldMigrate = true` - actively executing
- **completed** (exit 0): `ShouldMigrate = false` - already finished
- **failed** (non-zero exit): `ShouldMigrate = true` - retry on target

**Migration Steps** (`pkg/controller/migration.go`):
1. `captureContainerStates()` - Analyze original pod containers
2. `createCheckpoint()` - Create PVC (if preserve_pv: true)
3. `createOptimizedPod()` - Create pod with only running containers, wait for Ready (5min timeout)
4. `deleteOriginalPod()` - Graceful deletion (30s grace period)
5. `collectPostMigrationMetrics()` - Wait 30s, collect metrics

**API Endpoints**:
- `POST /api/v1/migrations` - Start migration
- `GET /api/v1/migrations/:id` - Get status
- `GET /api/v1/metrics` - Get performance metrics
- `GET /health` - Health check

## Testing

### Scheduler Testing
```bash
# Create test pod with custom scheduler
kubectl apply -f ai-storage-scheduler/deployments/test-gpu-pod.yaml

# Verify scheduling
kubectl get pods -o wide
kubectl describe pod <pod-name> | grep "Successfully assigned"

# Check scheduler logs
kubectl logs -n keti -l app=ai-storage-scheduler

# Check node resources
kubectl top nodes
kubectl describe node <node-name> | grep -A 5 Allocated
```

### Orchestrator Testing
```bash
# Port forward
kubectl port-forward -n kube-system svc/ai-storage-orchestrator 8080:8080

# Test migration
curl -X POST http://localhost:8080/api/v1/migrations \
  -H "Content-Type: application/json" \
  -d '{
    "pod_name": "example-pod",
    "pod_namespace": "default",
    "source_node": "worker-1",
    "target_node": "worker-2",
    "preserve_pv": true,
    "timeout": 600
  }'

# Check migration status
curl http://localhost:8080/api/v1/migrations/{migration-id}

# View metrics
curl http://localhost:8080/api/v1/metrics
```

### Running Unit Tests
```bash
# Orchestrator tests
cd ai-storage-orchestrator
go test ./pkg/...

# Run tests for any component
cd <component-directory>
go test ./...
```

## Common Development Patterns

### Adding a New Scheduler Plugin
1. Create plugin file in `ai-storage-scheduler/internal/framework/plugin/`
2. Implement `Plugin` interface and one of: `FilterPlugin`, `ScorePlugin`, `BindPlugin`
3. Register in `internal/config/config.go` in the appropriate slice
4. Test with sample workload

Example plugin structure:
```go
type MyPlugin struct{}

func NewMyPlugin() *MyPlugin { return &MyPlugin{} }
func (p *MyPlugin) Name() string { return "MyPlugin" }

func (p *MyPlugin) Filter(ctx context.Context, pod *v1.Pod, nodeInfo *utils.NodeInfo) *utils.Status {
    // Your filtering logic
    return utils.NewStatus(utils.Success, "")
}
```

### Modifying Migration Logic (Orchestrator)
1. Container state logic: `ai-storage-orchestrator/pkg/k8s/client.go:64-105`
2. Migration pipeline: `ai-storage-orchestrator/pkg/controller/migration.go:103-159`
3. Add new steps in `executeMigration()` function
4. Update `MigrationDetails` type if tracking new data

### Working with Metrics
- Scheduler GPU metrics: Background worker in `scheduler.go`, updated every 5 minutes
- Orchestrator metrics: Collected via `metrics.k8s.io/v1beta1` API
- Requires `metrics-server` deployed in cluster

## Important Architectural Notes

### Scheduler Specifics
- **Only schedules pods with**: `schedulerName: "ai-storage-scheduler"`
- **Cache synchronization**: Event-driven (Pod/Node informers)
- **Optimistic binding**: `assume()` updates cache before actual K8s binding
- **Sequential scheduling**: One pod at a time (not parallelized)
- **Known Issue**: LeastAllocated scoring returns 0, so node selection among feasible nodes may be arbitrary

### Orchestrator Specifics
- **State management**: In-memory only (no database), lost on restart
- **Migration isolation**: Each job runs in goroutine with context-based timeout
- **PVC naming**: `checkpoint-{podname}-{timestamp}`, 1Gi default, ReadWriteOnce
- **New pod naming**: `{original-name}-migrated-{timestamp}`
- **RBAC required**: Permissions for pods (get, create, delete), PVCs (create), metrics (get)

### Component Communication
- Scheduler → Kubernetes API (scheduling decisions)
- Orchestrator → Kubernetes API (pod migration, metrics)
- Metric Collector → gRPC (presumably, needs investigation)
- API Server → Unknown (needs investigation)

## Project-Specific Conventions

### Go Modules
Each component is an independent Go module with its own `go.mod`:
```bash
# Update dependencies for a component
cd <component-directory>
go mod tidy
go mod download
```

### Docker Image Naming
- Scheduler: `ketidevit2/keti-ai-storage-scheduler:latest`
- Orchestrator: `ai-storage-orchestrator:latest` (imported to containerd)
- Images use `imagePullPolicy: Never` - must be in local containerd

### Logging
- Scheduler: Uses structured logging (`internal/backend/log/logger.go`)
- Orchestrator: Standard Go logging
- View logs: `kubectl logs -n <namespace> -l app=<component>`

## Troubleshooting

### Scheduler Issues
**Pod stuck in Pending**:
- Check: `kubectl get pod <pod> -o yaml | grep schedulerName` (must be "ai-storage-scheduler")
- Check scheduler running: `kubectl get pods -n keti -l app=ai-storage-scheduler`
- View logs: `kubectl logs -n keti -l app=ai-storage-scheduler`

**Scheduler crashlooping**:
- Check previous logs: `kubectl logs -n keti -l app=ai-storage-scheduler --previous`
- Verify RBAC permissions configured
- Check node labels exist

### Orchestrator Issues
**Migration fails**:
- Check source pod exists: `kubectl get pod <pod-name> -n <namespace>`
- Verify target node exists: `kubectl get node <node-name>`
- Check RBAC permissions
- View orchestrator logs: `kubectl logs -n kube-system -l app=ai-storage-orchestrator`

**Metrics unavailable**:
- Verify metrics-server installed: `kubectl get deployment metrics-server -n kube-system`
- Orchestrator falls back to simulated values (50% CPU, 60% memory) if metrics API unavailable

## Known Limitations and TODOs

### Scheduler
1. LeastAllocated score plugin returns 0 (scoring logic exists but not integrated)
2. GPU metrics gRPC call not implemented (TODO at scheduler.go:157)
3. No actual GPU filter/score plugins (infrastructure ready)
4. No CSD-specific scheduling features implemented
5. No Prometheus metrics integration
6. Filter/Score phases not parallelized

### Orchestrator
1. No persistent state (in-memory only)
2. In-flight migrations interrupted on restart
3. No retry logic for failed migrations
4. No automatic rollback mechanism

### System-Wide
1. Component interdependencies not fully documented
2. End-to-end integration testing strategy needed
3. Performance benchmarks not automated

## Research Context

This system is based on research supported by IITP (Institute of Information & Communications Technology Planning & Evaluation), funded by Korea government (MSIT):
- Grant No. RS-2024-00461572
- Project: "Development of High-efficiency Parallel Storage SW Technology Optimized for AI Computational Accelerators"

The orchestrator implements concepts from the paper: "Optimized Container Pod Migration using Persistent Volume in Kubernetes"

Performance targets (vs standard Kubernetes):
- CPU usage: 50% (50% reduction)
- Memory usage: 60% (40% reduction)
- Cold start time: 50% (50% reduction via PV checkpoints)
