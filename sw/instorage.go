package main

import (
	"flag"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	_ "k8s.io/client-go/plugin/pkg/client/auth"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	instoragev1alpha1 "instorage-operator/pkg/apis/v1alpha1"
	"instorage-operator/pkg/controller"
)

var (
	scheme   = runtime.NewScheme()
	setupLog = ctrl.Log.WithName("setup")
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(instoragev1alpha1.AddToScheme(scheme))
}

func main() {
	var probeAddr string
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "The address the probe endpoint binds to.")
	opts := zap.Options{
		Development: true,
	}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		HealthProbeBindAddress: probeAddr,
	})
	if err != nil {
		setupLog.Error(err, "unable to start manager")
		os.Exit(1)
	}

	if err = (&controller.InstorageJobReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
		Log:    ctrl.Log.WithName("controllers").WithName("InstorageJob"),
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to create controller", "controller", "InstorageJob")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	setupLog.Info("starting manager")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "problem running manager")
		os.Exit(1)
	}
}

package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

type InstorageJobSpec struct {
	DataPath        string               `json:"dataPath"`
	OutputPath      string               `json:"outputPath"`
	Image           string               `json:"image"`
	ImagePullPolicy corev1.PullPolicy    `json:"imagePullPolicy,omitempty"`
	CSD             *CSDConfig           `json:"csd,omitempty"`
	DataLocations   *DataLocations       `json:"dataLocations,omitempty"`
	Preprocessing   *PreprocessingConfig `json:"preprocessing,omitempty"`
	Resources       *ResourceConfig      `json:"resources,omitempty"`
	NodeScheduling  *NodeScheduling      `json:"nodeScheduling,omitempty"`
	JobConfig       *JobConfig           `json:"jobConfig,omitempty"`
	Monitoring      *MonitoringConfig    `json:"monitoring,omitempty"`
	RetryPolicy     *RetryPolicy         `json:"retryPolicy,omitempty"`
}

type CSDConfig struct {
	Enabled         bool             `json:"enabled,omitempty"`
	DevicePath      string           `json:"devicePath,omitempty"`
	OffloadingRatio *OffloadingRatio `json:"offloadingRatio,omitempty"`
}

type OffloadingRatio struct {
	Request float64 `json:"request,omitempty"`
	Limit   float64 `json:"limit,omitempty"`
}

type DataLocations struct {
	Strategy  string           `json:"strategy,omitempty"`
	Locations []string         `json:"locations,omitempty"`
	Weights   []LocationWeight `json:"weights,omitempty"`
}

type LocationWeight struct {
	Location string `json:"location"`
	Weight   int    `json:"weight"`
}

type PreprocessingConfig struct {
	BatchSize       int `json:"batchSize,omitempty"`
	MaxLength       int `json:"maxLength,omitempty"`
	NSamples        int `json:"nSamples,omitempty"`
	ParallelWorkers int `json:"parallelWorkers,omitempty"`
	ChunkSize       int `json:"chunkSize,omitempty"`
}

type ResourceConfig struct {
	Requests *ResourceList `json:"requests,omitempty"`
	Limits   *ResourceList `json:"limits,omitempty"`
}

type ResourceList struct {
	CPU    string `json:"cpu,omitempty"`
	Memory string `json:"memory,omitempty"`
	GPU    string `json:"gpu,omitempty"`
}

type NodeScheduling struct {
	NodeName     string            `json:"nodeName,omitempty"`
	NodeSelector map[string]string `json:"nodeSelector,omitempty"`
	Affinity     interface{}       `json:"affinity,omitempty"`
}

type JobConfig struct {
	Completions             int `json:"completions,omitempty"`
	Parallelism             int `json:"parallelism,omitempty"`
	BackoffLimit            int `json:"backoffLimit,omitempty"`
	TTLSecondsAfterFinished int `json:"ttlSecondsAfterFinished,omitempty"`
	ActiveDeadlineSeconds   int `json:"activeDeadlineSeconds,omitempty"`
}

type MonitoringConfig struct {
	Enabled          bool              `json:"enabled,omitempty"`
	MetricsPort      int               `json:"metricsPort,omitempty"`
	LogLevel         string            `json:"logLevel,omitempty"`
	PrometheusLabels map[string]string `json:"prometheusLabels,omitempty"`
}

type RetryPolicy struct {
	MaxRetries         int  `json:"maxRetries,omitempty"`
	RetryInterval      int  `json:"retryInterval,omitempty"`
	ExponentialBackoff bool `json:"exponentialBackoff,omitempty"`
}

type InstorageJobStatus struct {
	Phase            JobPhase       `json:"phase,omitempty"`
	StartTime        *metav1.Time   `json:"startTime,omitempty"`
	CompletionTime   *metav1.Time   `json:"completionTime,omitempty"`
	ProcessedRecords int            `json:"processedRecords,omitempty"`
	TotalRecords     int            `json:"totalRecords,omitempty"`
	CSDUtilization   float64        `json:"csdUtilization,omitempty"`
	Message          string         `json:"message,omitempty"`
	TargetNode       string         `json:"targetNode,omitempty"`
	Conditions       []JobCondition `json:"conditions,omitempty"`
}

type JobCondition struct {
	Type               string      `json:"type"`
	Status             string      `json:"status"`
	LastTransitionTime metav1.Time `json:"lastTransitionTime"`
	Reason             string      `json:"reason,omitempty"`
	Message            string      `json:"message,omitempty"`
}

type JobPhase string

const (
	JobPhasePending   JobPhase = "Pending"
	JobPhaseRunning   JobPhase = "Running"
	JobPhaseSucceeded JobPhase = "Succeeded"
	JobPhaseFailed    JobPhase = "Failed"
	JobPhaseUnknown   JobPhase = "Unknown"
)

type InstorageJob struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              InstorageJobSpec   `json:"spec,omitempty"`
	Status            InstorageJobStatus `json:"status,omitempty"`
}

type InstorageJobList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []InstorageJob `json:"items"`
}

var (
	SchemeGroupVersion = schema.GroupVersion{Group: "batch.csd.io", Version: "v1alpha1"}
	SchemeBuilder = runtime.NewSchemeBuilder(addKnownTypes)
	AddToScheme = SchemeBuilder.AddToScheme
)

func (in *InstorageJob) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *InstorageJob) DeepCopy() *InstorageJob {
	if in == nil {
		return nil
	}
	out := new(InstorageJob)
	in.DeepCopyInto(out)
	return out
}

func (in *InstorageJob) DeepCopyInto(out *InstorageJob) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	in.Spec.DeepCopyInto(&out.Spec)
	in.Status.DeepCopyInto(&out.Status)
}

func (in *InstorageJobList) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *InstorageJobList) DeepCopy() *InstorageJobList {
	if in == nil {
		return nil
	}
	out := new(InstorageJobList)
	in.DeepCopyInto(out)
	return out
}

func (in *InstorageJobList) DeepCopyInto(out *InstorageJobList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		in, out := &in.Items, &out.Items
		*out = make([]InstorageJob, len(*in))
		for i := range *in {
			(*in)[i].DeepCopyInto(&(*out)[i])
		}
	}
}

func (in *InstorageJobSpec) DeepCopyInto(out *InstorageJobSpec) {
	*out = *in
	if in.CSD != nil {
		in, out := &in.CSD, &out.CSD
		*out = new(CSDConfig)
		(*in).DeepCopyInto(*out)
	}
	if in.DataLocations != nil {
		in, out := &in.DataLocations, &out.DataLocations
		*out = new(DataLocations)
		(*in).DeepCopyInto(*out)
	}
	if in.Preprocessing != nil {
		in, out := &in.Preprocessing, &out.Preprocessing
		*out = new(PreprocessingConfig)
		**out = **in
	}
	if in.Resources != nil {
		in, out := &in.Resources, &out.Resources
		*out = new(ResourceConfig)
		(*in).DeepCopyInto(*out)
	}
	if in.NodeScheduling != nil {
		in, out := &in.NodeScheduling, &out.NodeScheduling
		*out = new(NodeScheduling)
		(*in).DeepCopyInto(*out)
	}
	if in.JobConfig != nil {
		in, out := &in.JobConfig, &out.JobConfig
		*out = new(JobConfig)
		**out = **in
	}
	if in.Monitoring != nil {
		in, out := &in.Monitoring, &out.Monitoring
		*out = new(MonitoringConfig)
		(*in).DeepCopyInto(*out)
	}
	if in.RetryPolicy != nil {
		in, out := &in.RetryPolicy, &out.RetryPolicy
		*out = new(RetryPolicy)
		**out = **in
	}
}

func (in *InstorageJobSpec) DeepCopy() *InstorageJobSpec {
	if in == nil {
		return nil
	}
	out := new(InstorageJobSpec)
	in.DeepCopyInto(out)
	return out
}

func (in *InstorageJobStatus) DeepCopyInto(out *InstorageJobStatus) {
	*out = *in
	if in.StartTime != nil {
		in, out := &in.StartTime, &out.StartTime
		*out = (*in).DeepCopy()
	}
	if in.CompletionTime != nil {
		in, out := &in.CompletionTime, &out.CompletionTime
		*out = (*in).DeepCopy()
	}
	if in.Conditions != nil {
		in, out := &in.Conditions, &out.Conditions
		*out = make([]JobCondition, len(*in))
		for i := range *in {
			(*in)[i].DeepCopyInto(&(*out)[i])
		}
	}
}

func (in *InstorageJobStatus) DeepCopy() *InstorageJobStatus {
	if in == nil {
		return nil
	}
	out := new(InstorageJobStatus)
	in.DeepCopyInto(out)
	return out
}

func (in *CSDConfig) DeepCopyInto(out *CSDConfig) {
	*out = *in
	if in.OffloadingRatio != nil {
		in, out := &in.OffloadingRatio, &out.OffloadingRatio
		*out = new(OffloadingRatio)
		**out = **in
	}
}

func (in *DataLocations) DeepCopyInto(out *DataLocations) {
	*out = *in
	if in.Locations != nil {
		in, out := &in.Locations, &out.Locations
		*out = make([]string, len(*in))
		copy(*out, *in)
	}
	if in.Weights != nil {
		in, out := &in.Weights, &out.Weights
		*out = make([]LocationWeight, len(*in))
		copy(*out, *in)
	}
}

func (in *ResourceConfig) DeepCopyInto(out *ResourceConfig) {
	*out = *in
	if in.Requests != nil {
		in, out := &in.Requests, &out.Requests
		*out = new(ResourceList)
		**out = **in
	}
	if in.Limits != nil {
		in, out := &in.Limits, &out.Limits
		*out = new(ResourceList)
		**out = **in
	}
}

func (in *NodeScheduling) DeepCopyInto(out *NodeScheduling) {
	*out = *in
	if in.NodeSelector != nil {
		in, out := &in.NodeSelector, &out.NodeSelector
		*out = make(map[string]string, len(*in))
		for key, val := range *in {
			(*out)[key] = val
		}
	}
}

func (in *MonitoringConfig) DeepCopyInto(out *MonitoringConfig) {
	*out = *in
	if in.PrometheusLabels != nil {
		in, out := &in.PrometheusLabels, &out.PrometheusLabels
		*out = make(map[string]string, len(*in))
		for key, val := range *in {
			(*out)[key] = val
		}
	}
}

func (in *JobCondition) DeepCopyInto(out *JobCondition) {
	*out = *in
	in.LastTransitionTime.DeepCopyInto(&out.LastTransitionTime)
}

func addKnownTypes(scheme *runtime.Scheme) error {
	scheme.AddKnownTypes(SchemeGroupVersion,
		&InstorageJob{},
		&InstorageJobList{},
	)
	metav1.AddToGroupVersion(scheme, SchemeGroupVersion)
	return nil
}

package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-logr/logr"
	"go.uber.org/zap/zapcore"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	"instorage-manager/pkg/manager"
	pb "instorage-manager/pkg/proto"
)

const (
	DefaultGRPCPort    = "50051"
	DefaultCSDEndpoint = "http://localhost:8080"
)

func main() {
	var (
		grpcPort         = flag.String("grpc-port", DefaultGRPCPort, "gRPC server port")
		nodeName         = flag.String("node-name", "", "Node name this manager runs on")
		csdEndpoint      = flag.String("csd-endpoint", DefaultCSDEndpoint, "CSD processor endpoint")
		enableReflection = flag.Bool("enable-reflection", true, "Enable gRPC reflection")
	)

	opts := zap.Options{
		Development: true,
		TimeEncoder: func(t time.Time, enc zapcore.PrimitiveArrayEncoder) {
			enc.AppendString(t.Format("2006-01-02 15:04:05"))
		},
	}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()

	logger := zap.New(zap.UseFlagOptions(&opts))
	ctrl.SetLogger(logger)

	if *nodeName == "" {
		*nodeName = os.Getenv("NODE_NAME")
		if *nodeName == "" {
			logger.Error(fmt.Errorf("node name not provided"),
				"node name must be set via --node-name flag or NODE_NAME env var")
			os.Exit(1)
		}
	}

	logger.Info("Starting Instorage Manager",
		"nodeName", *nodeName,
		"grpcPort", *grpcPort,
		"csdEndpoint", *csdEndpoint,
	)

	grpcServer := grpc.NewServer(
		grpc.UnaryInterceptor(loggingInterceptor(logger)),
	)

	instorageServer := manager.NewInstorageManagerServer(logger, *nodeName, *csdEndpoint)
	pb.RegisterInstorageManagerServer(grpcServer, instorageServer)

	healthServer := health.NewServer()
	grpc_health_v1.RegisterHealthServer(grpcServer, healthServer)
	healthServer.SetServingStatus("", grpc_health_v1.HealthCheckResponse_SERVING)

	if *enableReflection {
		reflection.Register(grpcServer)
		logger.Info("gRPC reflection enabled")
	}

	lis, err := net.Listen("tcp", fmt.Sprintf(":%s", *grpcPort))
	if err != nil {
		logger.Error(err, "Failed to listen on port", "port", *grpcPort)
		os.Exit(1)
	}

	go func() {
		logger.Info("Starting gRPC server", "address", lis.Addr().String())
		if err := grpcServer.Serve(lis); err != nil {
			logger.Error(err, "gRPC server failed")
			os.Exit(1)
		}
	}()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	sig := <-sigChan
	logger.Info("Received shutdown signal", "signal", sig.String())

	logger.Info("Shutting down gRPC server...")
	healthServer.SetServingStatus("", grpc_health_v1.HealthCheckResponse_NOT_SERVING)

	grpcServer.GracefulStop()

	logger.Info("Instorage Manager stopped")
}

func loggingInterceptor(logger logr.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		start := time.Now()

		resp, err := handler(ctx, req)

		duration := time.Since(start)

		if err != nil {
			logger.Error(err, "gRPC call failed",
				"method", info.FullMethod,
				"duration", duration,
			)
		} else {
			logger.V(1).Info("gRPC call completed",
				"method", info.FullMethod,
				"duration", duration,
			)
		}

		return resp, err
	}
}

package manager

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/go-logr/logr"
	"google.golang.org/protobuf/types/known/timestamppb"

	pb "instorage-manager/pkg/proto"
)

type ContainerJobRequest struct {
	JobID           string            `json:"job_id"`
	JobName         string            `json:"job_name"`
	Namespace       string            `json:"namespace"`
	Image           string            `json:"image"`
	ImagePullPolicy string            `json:"image_pull_policy,omitempty"`
	DataPath        string            `json:"data_path"`
	OutputPath      string            `json:"output_path"`
	Environment     map[string]string `json:"environment,omitempty"`
	Resources       *ContainerResources `json:"resources,omitempty"`
	Labels          map[string]string `json:"labels,omitempty"`
}

type ContainerResources struct {
	CPULimit    string `json:"cpu_limit,omitempty"`
	MemoryLimit string `json:"memory_limit,omitempty"`
	CPURequest  string `json:"cpu_request,omitempty"`
	MemoryRequest string `json:"memory_request,omitempty"`
}

type ContainerJobResponse struct {
	Success   bool   `json:"success"`
	Message   string `json:"message"`
	JobID     string `json:"job_id"`
	ContainerID string `json:"container_id,omitempty"`
}

type ContainerJobStatus struct {
	JobID       string `json:"job_id"`
	ContainerID string `json:"container_id,omitempty"`
	Status      string `json:"status"` 
	Message     string `json:"message"`
	StartTime   string `json:"start_time,omitempty"`
	EndTime     string `json:"end_time,omitempty"`
	ExitCode    int    `json:"exit_code,omitempty"`
	OutputPath  string `json:"output_path,omitempty"`
	ErrorMessage string `json:"error_message,omitempty"`
}

type JobState struct {
	Request        *pb.SubmitJobRequest
	Status         pb.JobStatus
	Message        string
	StartTime      *timestamppb.Timestamp
	CompletionTime *timestamppb.Timestamp
	OutputPath     string
	ErrorMessage   string
}

type InstorageManagerServer struct {
	pb.UnimplementedInstorageManagerServer

	logger      logr.Logger
	nodeName    string
	csdEndpoint string
	httpClient  *http.Client
	jobs   map[string]*JobState
	jobMux sync.RWMutex
}

func NewInstorageManagerServer(logger logr.Logger, nodeName, csdEndpoint string) *InstorageManagerServer {
	return &InstorageManagerServer{
		logger:      logger,
		nodeName:    nodeName,
		csdEndpoint: csdEndpoint,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		jobs:        make(map[string]*JobState),
	}
}

func (s *InstorageManagerServer) SubmitJob(ctx context.Context, req *pb.SubmitJobRequest) (*pb.SubmitJobResponse, error) {
	s.logger.Info("Received job submission request",
		"jobId", req.JobId,
		"jobName", req.JobName,
		"namespace", req.Namespace,
		"targetNode", req.TargetNode,
	)

	if req.JobId == "" {
		return &pb.SubmitJobResponse{
			Success: false,
			Message: "job_id is required",
		}, nil
	}

	if req.JobName == "" {
		return &pb.SubmitJobResponse{
			Success: false,
			Message: "job_name is required",
		}, nil
	}

	if req.Image == "" {
		return &pb.SubmitJobResponse{
			Success: false,
			Message: "image is required",
		}, nil
	}

	s.jobMux.RLock()
	existingJob, exists := s.jobs[req.JobId]
	s.jobMux.RUnlock()

	if exists {
		return &pb.SubmitJobResponse{
			Success: false,
			Message: fmt.Sprintf("job with ID %s already exists with status %v", req.JobId, existingJob.Status),
		}, nil
	}

	now := timestamppb.Now()
	jobState := &JobState{
		Request:   req,
		Status:    pb.JobStatus_JOB_STATUS_PENDING,
		Message:   "Job received and queued for processing",
		StartTime: now,
	}

	s.jobMux.Lock()
	s.jobs[req.JobId] = jobState
	s.jobMux.Unlock()

	go s.processJob(req.JobId)

	s.logger.Info("Job accepted successfully",
		"jobId", req.JobId,
		"jobName", req.JobName,
	)

	return &pb.SubmitJobResponse{
		Success:     true,
		Message:     "Job submitted successfully",
		JobId:       req.JobId,
		SubmittedAt: now,
	}, nil
}

func (s *InstorageManagerServer) GetJobStatus(ctx context.Context, req *pb.GetJobStatusRequest) (*pb.GetJobStatusResponse, error) {
	s.logger.V(1).Info("Job status request", "jobId", req.JobId)

	if req.JobId == "" {
		return &pb.GetJobStatusResponse{
			JobId:        "",
			Status:       pb.JobStatus_JOB_STATUS_UNKNOWN,
			Message:      "job_id is required",
			ErrorMessage: "job_id parameter is missing",
		}, nil
	}

	s.jobMux.RLock()
	jobState, exists := s.jobs[req.JobId]
	s.jobMux.RUnlock()

	if !exists {
		return &pb.GetJobStatusResponse{
			JobId:        req.JobId,
			Status:       pb.JobStatus_JOB_STATUS_UNKNOWN,
			Message:      "Job not found",
			ErrorMessage: fmt.Sprintf("no job found with ID: %s", req.JobId),
		}, nil
	}

	return &pb.GetJobStatusResponse{
		JobId:          req.JobId,
		Status:         jobState.Status,
		Message:        jobState.Message,
		StartTime:      jobState.StartTime,
		CompletionTime: jobState.CompletionTime,
		OutputPath:     jobState.OutputPath,
		ErrorMessage:   jobState.ErrorMessage,
	}, nil
}

func (s *InstorageManagerServer) CancelJob(ctx context.Context, req *pb.CancelJobRequest) (*pb.CancelJobResponse, error) {
	s.logger.Info("Job cancellation request", "jobId", req.JobId, "reason", req.Reason)

	if req.JobId == "" {
		return &pb.CancelJobResponse{
			Success: false,
			Message: "job_id is required",
		}, nil
	}

	s.jobMux.Lock()
	defer s.jobMux.Unlock()

	jobState, exists := s.jobs[req.JobId]
	if !exists {
		return &pb.CancelJobResponse{
			Success: false,
			Message: fmt.Sprintf("job with ID %s not found", req.JobId),
		}, nil
	}

	// Check if job can be cancelled
	if jobState.Status == pb.JobStatus_JOB_STATUS_COMPLETED ||
		jobState.Status == pb.JobStatus_JOB_STATUS_FAILED ||
		jobState.Status == pb.JobStatus_JOB_STATUS_CANCELLED {
		return &pb.CancelJobResponse{
			Success: false,
			Message: fmt.Sprintf("job cannot be cancelled, current status: %v", jobState.Status),
		}, nil
	}

	now := timestamppb.Now()
	jobState.Status = pb.JobStatus_JOB_STATUS_CANCELLED
	jobState.Message = "Job cancelled by user request"
	if req.Reason != "" {
		jobState.Message = fmt.Sprintf("Job cancelled: %s", req.Reason)
	}
	jobState.CompletionTime = now

	s.logger.Info("Job cancelled successfully", "jobId", req.JobId)

	return &pb.CancelJobResponse{
		Success:     true,
		Message:     "Job cancelled successfully",
		CancelledAt: now,
	}, nil
}

func (s *InstorageManagerServer) ListNodes(ctx context.Context, req *pb.ListNodesRequest) (*pb.ListNodesResponse, error) {
	s.logger.V(1).Info("Node list request", "csdOnly", req.CsdOnly)
	nodes := []*pb.NodeResources{
		{
			NodeName:        s.nodeName,
			CpuCapacity:     "4",
			MemoryCapacity:  "8Gi",
			CpuAvailable:    "2",
			MemoryAvailable: "4Gi",
			RunningJobs:     s.getRunningJobCount(),
			CsdEnabled:      true,
			CsdStatus:       "ready",
		},
	}

	return &pb.ListNodesResponse{
		Nodes: nodes,
	}, nil
}

func (s *InstorageManagerServer) processJob(jobId string) {
	s.logger.Info("Starting job processing", "jobId", jobId)

	s.jobMux.RLock()
	jobState, exists := s.jobs[jobId]
	s.jobMux.RUnlock()

	if !exists {
		s.logger.Error(fmt.Errorf("job not found"), "Failed to process job", "jobId", jobId)
		return
	}

	if jobState.Status == pb.JobStatus_JOB_STATUS_CANCELLED {
		s.logger.Info("Job was cancelled before processing started", "jobId", jobId)
		return
	}

	err := s.submitToContainerProcessor(jobState.Request)
	if err != nil {
		s.logger.Error(err, "Failed to submit job to container processor", "jobId", jobId)
		s.jobMux.Lock()
		jobState.Status = pb.JobStatus_JOB_STATUS_FAILED
		jobState.Message = fmt.Sprintf("Failed to submit to container processor: %v", err)
		jobState.CompletionTime = timestamppb.Now()
		jobState.ErrorMessage = err.Error()
		s.jobMux.Unlock()
		return
	}

	s.jobMux.Lock()
	jobState.Status = pb.JobStatus_JOB_STATUS_RUNNING
	jobState.Message = "Job submitted to container processor"
	s.jobMux.Unlock()

	s.logger.Info("Job submitted to container processor", "jobId", jobId)

	s.monitorJob(jobId)
}

func (s *InstorageManagerServer) submitToContainerProcessor(req *pb.SubmitJobRequest) error {
	containerReq := &ContainerJobRequest{
		JobID:           req.JobId,
		JobName:         req.JobName,
		Namespace:       req.Namespace,
		Image:           req.Image,
		ImagePullPolicy: req.ImagePullPolicy,
		DataPath:        req.DataPath,
		OutputPath:      req.OutputPath,
		Environment:     s.buildEnvironmentVariables(req),
		Resources:       s.convertResources(req.Resources),
		Labels:          req.Labels,
	}

	jsonData, err := json.Marshal(containerReq)
	if err != nil {
		return fmt.Errorf("failed to marshal container request: %w", err)
	}

	url := fmt.Sprintf("%s/api/v1/jobs", s.csdEndpoint)
	httpReq, err := http.NewRequest("POST", url, bytes.NewBuffer(jsonData))
	if err != nil {
		return fmt.Errorf("failed to create HTTP request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(httpReq)
	if err != nil {
		return fmt.Errorf("failed to send request to container processor: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted {
		return fmt.Errorf("container processor returned status %d", resp.StatusCode)
	}

	var containerResp ContainerJobResponse
	if err := json.NewDecoder(resp.Body).Decode(&containerResp); err != nil {
		return fmt.Errorf("failed to decode container processor response: %w", err)
	}

	if !containerResp.Success {
		return fmt.Errorf("container processor rejected job: %s", containerResp.Message)
	}

	s.logger.Info("Job successfully submitted to container processor",
		"jobId", containerReq.JobID,
		"containerId", containerResp.ContainerID,
		"message", containerResp.Message,
	)

	return nil
}

func (s *InstorageManagerServer) monitorJob(jobId string) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	s.logger.Info("Starting job monitoring", "jobId", jobId)

	for {
		select {
		case <-ticker.C:
			s.jobMux.RLock()
			jobState, exists := s.jobs[jobId]
			if !exists || jobState.Status == pb.JobStatus_JOB_STATUS_CANCELLED {
				s.jobMux.RUnlock()
				s.logger.Info("Job monitoring stopped - job was cancelled", "jobId", jobId)
				return
			}
			s.jobMux.RUnlock()

			status, err := s.getJobStatusFromContainerProcessor(jobId)
			if err != nil {
				s.logger.Error(err, "Failed to get job status from container processor", "jobId", jobId)
				continue
			}

			s.updateJobStateFromContainer(jobId, status)

			if status.Status == "completed" || status.Status == "failed" || status.Status == "cancelled" {
				s.logger.Info("Job monitoring completed", "jobId", jobId, "finalStatus", status.Status)
				return
			}
		}
	}
}

func (s *InstorageManagerServer) getJobStatusFromContainerProcessor(jobId string) (*ContainerJobStatus, error) {
	url := fmt.Sprintf("%s/api/v1/jobs/%s/status", s.csdEndpoint, jobId)
	
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create HTTP request: %w", err)
	}

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to send request to container processor: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("container processor returned status %d", resp.StatusCode)
	}

	var status ContainerJobStatus
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		return nil, fmt.Errorf("failed to decode status response: %w", err)
	}

	return &status, nil
}

func (s *InstorageManagerServer) updateJobStateFromContainer(jobId string, containerStatus *ContainerJobStatus) {
	s.jobMux.Lock()
	defer s.jobMux.Unlock()

	jobState, exists := s.jobs[jobId]
	if !exists {
		return
	}

	var grpcStatus pb.JobStatus
	switch containerStatus.Status {
	case "pending":
		grpcStatus = pb.JobStatus_JOB_STATUS_PENDING
	case "running":
		grpcStatus = pb.JobStatus_JOB_STATUS_RUNNING
	case "completed":
		grpcStatus = pb.JobStatus_JOB_STATUS_COMPLETED
		jobState.CompletionTime = timestamppb.Now()
		jobState.OutputPath = containerStatus.OutputPath
	case "failed":
		grpcStatus = pb.JobStatus_JOB_STATUS_FAILED
		jobState.CompletionTime = timestamppb.Now()
		jobState.ErrorMessage = containerStatus.ErrorMessage
	case "cancelled":
		grpcStatus = pb.JobStatus_JOB_STATUS_CANCELLED
		jobState.CompletionTime = timestamppb.Now()
	default:
		grpcStatus = pb.JobStatus_JOB_STATUS_UNKNOWN
	}

	jobState.Status = grpcStatus
	jobState.Message = containerStatus.Message

	s.logger.V(1).Info("Updated job state from container processor",
		"jobId", jobId,
		"status", containerStatus.Status,
		"message", containerStatus.Message,
	)
}

func (s *InstorageManagerServer) buildEnvironmentVariables(req *pb.SubmitJobRequest) map[string]string {
	env := map[string]string{
		"DATA_PATH":   req.DataPath,
		"OUTPUT_PATH": req.OutputPath,
	}

	if req.Preprocessing != nil {
		if req.Preprocessing.BatchSize > 0 {
			env["BATCH_SIZE"] = fmt.Sprintf("%d", req.Preprocessing.BatchSize)
		}
		if req.Preprocessing.MaxLength > 0 {
			env["MAX_LENGTH"] = fmt.Sprintf("%d", req.Preprocessing.MaxLength)
		}
		if req.Preprocessing.NSamples > 0 {
			env["N_SAMPLES"] = fmt.Sprintf("%d", req.Preprocessing.NSamples)
		}
		if req.Preprocessing.ParallelWorkers > 0 {
			env["PARALLEL_WORKERS"] = fmt.Sprintf("%d", req.Preprocessing.ParallelWorkers)
		}
		if req.Preprocessing.ChunkSize > 0 {
			env["CHUNK_SIZE"] = fmt.Sprintf("%d", req.Preprocessing.ChunkSize)
		}
	}

	if req.DataLocations != nil {
		if len(req.DataLocations.Locations) > 0 {
			locationsJson, _ := json.Marshal(req.DataLocations.Locations)
			env["DATA_LOCATIONS"] = string(locationsJson)
		}
		if req.DataLocations.Strategy != "" {
			env["DATA_STRATEGY"] = req.DataLocations.Strategy
		}
	}

	if req.Csd != nil && req.Csd.Enabled {
		env["CSD_ENABLED"] = "true"
		if req.Csd.DevicePath != "" {
			env["CSD_DEVICE_PATH"] = req.Csd.DevicePath
		}
	}

	return env
}

func (s *InstorageManagerServer) convertResources(res *pb.Resources) *ContainerResources {
	if res == nil {
		return nil
	}

	containerRes := &ContainerResources{}

	if res.Requests != nil {
		containerRes.CPURequest = res.Requests.Cpu
		containerRes.MemoryRequest = res.Requests.Memory
	}

	if res.Limits != nil {
		containerRes.CPULimit = res.Limits.Cpu
		containerRes.MemoryLimit = res.Limits.Memory
	}

	return containerRes
}

func (s *InstorageManagerServer) getRunningJobCount() int32 {
	s.jobMux.RLock()
	defer s.jobMux.RUnlock()

	count := int32(0)
	for _, job := range s.jobs {
		if job.Status == pb.JobStatus_JOB_STATUS_RUNNING {
			count++
		}
	}
	return count
}

func (s *InstorageManagerServer) GetJobCount() int {
	s.jobMux.RLock()
	defer s.jobMux.RUnlock()
	return len(s.jobs)
}

