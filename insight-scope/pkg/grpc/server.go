package grpc

import (
	"context"
	"fmt"
	"log"
	"net"
	"time"

	"insight-scope/pkg/controller"
	"insight-scope/pkg/types"
	pb "insight-scope/proto/scopepb"

	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

// ScopeServer implements the InsightScopeService gRPC server
type ScopeServer struct {
	pb.UnimplementedInsightScopeServiceServer
	controller *controller.ScopeController
	grpcServer *grpc.Server
	port       string
}

// NewScopeServer creates a new gRPC server
func NewScopeServer(ctrl *controller.ScopeController, port string) *ScopeServer {
	return &ScopeServer{
		controller: ctrl,
		port:       port,
	}
}

// Start starts the gRPC server
func (s *ScopeServer) Start() error {
	lis, err := net.Listen("tcp", ":"+s.port)
	if err != nil {
		return fmt.Errorf("failed to listen: %w", err)
	}

	s.grpcServer = grpc.NewServer()
	pb.RegisterInsightScopeServiceServer(s.grpcServer, s)

	// Enable reflection for debugging
	reflection.Register(s.grpcServer)

	log.Printf("Insight Scope gRPC server starting on port %s", s.port)

	go func() {
		if err := s.grpcServer.Serve(lis); err != nil {
			log.Printf("gRPC server error: %v", err)
		}
	}()

	return nil
}

// Stop gracefully stops the gRPC server
func (s *ScopeServer) Stop() {
	if s.grpcServer != nil {
		s.grpcServer.GracefulStop()
	}
}

// AnalyzePod analyzes a pod
func (s *ScopeServer) AnalyzePod(ctx context.Context, req *pb.AnalyzePodRequest) (*pb.AnalyzePodResponse, error) {
	analysisReq := &types.ScopeAnalysisRequest{
		IncludeTraceData: req.IncludeTraceData,
		WaitForTrace:     req.WaitForTrace,
	}

	// Handle oneof target
	switch target := req.Target.(type) {
	case *pb.AnalyzePodRequest_PodYaml:
		analysisReq.PodYAML = target.PodYaml
	case *pb.AnalyzePodRequest_PodRef:
		analysisReq.PodName = target.PodRef.Name
		analysisReq.Namespace = target.PodRef.Namespace
	}

	result, err := s.controller.AnalyzePod(ctx, analysisReq)
	if err != nil {
		return nil, err
	}

	return convertToProtoResponse(result), nil
}

// GetCachedAnalysis retrieves cached analysis
func (s *ScopeServer) GetCachedAnalysis(ctx context.Context, req *pb.GetCachedAnalysisRequest) (*pb.AnalyzePodResponse, error) {
	result := s.controller.GetCachedAnalysis(req.Namespace, req.PodName)
	if result == nil {
		return nil, fmt.Errorf("no cached analysis found for %s/%s", req.Namespace, req.PodName)
	}
	return convertToProtoResponse(result), nil
}

// AnalyzeNamespace analyzes all pods in a namespace
func (s *ScopeServer) AnalyzeNamespace(ctx context.Context, req *pb.AnalyzeNamespaceRequest) (*pb.AnalyzeNamespaceResponse, error) {
	results, err := s.controller.AnalyzeAllPods(ctx, req.Namespace)
	if err != nil {
		return nil, err
	}

	resp := &pb.AnalyzeNamespaceResponse{
		Namespace:  req.Namespace,
		TotalCount: int32(len(results)),
	}

	for _, r := range results {
		resp.Analyses = append(resp.Analyses, convertToProtoResponse(r))
	}

	return resp, nil
}

// GetModelProfile retrieves a model profile
func (s *ScopeServer) GetModelProfile(ctx context.Context, req *pb.GetModelProfileRequest) (*pb.ModelProfileResponse, error) {
	profile := s.controller.GetModelProfile(types.AIModelType(req.ModelType))
	if profile == nil {
		return nil, fmt.Errorf("model profile not found: %s", req.ModelType)
	}

	return &pb.ModelProfileResponse{
		Profile: convertModelProfileToProto(profile),
	}, nil
}

// SearchModels searches for models by keyword
func (s *ScopeServer) SearchModels(ctx context.Context, req *pb.SearchModelsRequest) (*pb.SearchModelsResponse, error) {
	models := s.controller.SearchModels(req.Keyword)

	resp := &pb.SearchModelsResponse{
		Query: req.Keyword,
		Count: int32(len(models)),
	}

	for _, model := range models {
		profile := s.controller.GetModelProfile(model)
		if profile != nil {
			resp.Results = append(resp.Results, &pb.ModelSearchResult{
				ModelType: string(model),
				Category:  convertModelCategoryToProto(profile.ModelCategory),
				Profile:   convertModelProfileToProto(profile),
			})
		}
	}

	return resp, nil
}

// ListAllModels returns all known models
func (s *ScopeServer) ListAllModels(ctx context.Context, req *pb.ListAllModelsRequest) (*pb.ListAllModelsResponse, error) {
	models := s.controller.ListAllModels()

	resp := &pb.ListAllModelsResponse{
		TotalCount: int32(len(models)),
		ByCategory: make(map[string]*pb.ModelList),
	}

	// Group by category
	for _, model := range models {
		profile := s.controller.GetModelProfile(model)
		if profile != nil {
			category := string(profile.ModelCategory)
			if resp.ByCategory[category] == nil {
				resp.ByCategory[category] = &pb.ModelList{}
			}
			resp.ByCategory[category].Models = append(resp.ByCategory[category].Models, string(model))
		}
		resp.AllModels = append(resp.AllModels, string(model))
	}

	return resp, nil
}

// GetStorageRecommendation returns storage recommendation
func (s *ScopeServer) GetStorageRecommendation(ctx context.Context, req *pb.GetRecommendationRequest) (*pb.StorageRecommendationResponse, error) {
	var recommendation *types.StorageRecommendation

	switch criteria := req.Criteria.(type) {
	case *pb.GetRecommendationRequest_ModelType:
		profile := s.controller.GetModelProfile(types.AIModelType(criteria.ModelType))
		if profile != nil {
			recommendation = &types.StorageRecommendation{
				StorageClass:   profile.RecommendedStorageClass,
				StorageSize:    profile.RecommendedStorageSize,
				IOPS:           profile.RecommendedIOPS,
				ThroughputMBps: profile.RecommendedThroughput,
				AccessMode:     "ReadWriteOnce",
				Reasoning:      fmt.Sprintf("Based on %s model profile", criteria.ModelType),
			}
		}
	case *pb.GetRecommendationRequest_ModelCategory:
		// Parse the string category to enum
		category := parseModelCategoryString(criteria.ModelCategory)
		recommendation = getRecommendationByCategory(category)
	}

	if recommendation == nil {
		recommendation = &types.StorageRecommendation{
			StorageClass:   "standard",
			StorageSize:    "200Gi",
			IOPS:           3000,
			ThroughputMBps: 200,
			AccessMode:     "ReadWriteOnce",
			Reasoning:      "Default recommendation",
		}
	}

	return &pb.StorageRecommendationResponse{
		Recommendation: convertStorageRecommendationToProto(recommendation),
	}, nil
}

// GetCategoryRecommendation returns recommendation by category
func (s *ScopeServer) GetCategoryRecommendation(ctx context.Context, req *pb.GetCategoryRecommendationRequest) (*pb.StorageRecommendationResponse, error) {
	recommendation := getRecommendationByCategory(convertProtoToModelCategory(req.Category))

	return &pb.StorageRecommendationResponse{
		Recommendation: convertStorageRecommendationToProto(recommendation),
	}, nil
}

// StreamAnalysisResults streams analysis results (not implemented yet)
func (s *ScopeServer) StreamAnalysisResults(req *pb.StreamAnalysisRequest, stream pb.InsightScopeService_StreamAnalysisResultsServer) error {
	// TODO: Implement streaming
	return fmt.Errorf("streaming not yet implemented")
}

// HealthCheck returns health status
func (s *ScopeServer) HealthCheck(ctx context.Context, req *pb.HealthCheckRequest) (*pb.HealthCheckResponse, error) {
	return &pb.HealthCheckResponse{
		Healthy:       true,
		Component:     "insight-scope",
		TimestampUnix: time.Now().Unix(),
	}, nil
}

// ============================================
// Conversion Helpers
// ============================================

func convertToProtoResponse(result *types.ScopeAnalysisResult) *pb.AnalyzePodResponse {
	resp := &pb.AnalyzePodResponse{
		AnalysisId:    result.AnalysisID,
		PodName:       result.PodName,
		PodNamespace:  result.PodNamespace,
		ContainerName: result.ContainerName,
		CurrentStage:  convertPipelineStageToProto(result.CurrentStage),
		AnalyzedAtUnix:     result.AnalyzedAt.Unix(),
		AnalysisDurationMs: result.AnalysisDuration,
	}

	if result.YAMLAnalysis != nil {
		resp.YamlAnalysis = convertYAMLAnalysisToProto(result.YAMLAnalysis)
	}

	if result.TraceAnalysis != nil {
		resp.TraceAnalysis = convertTraceAnalysisToProto(result.TraceAnalysis)
	}

	if result.ModelSignature != nil {
		resp.ModelSignature = convertModelSignatureToProto(result.ModelSignature)
	}

	if result.StorageRecommendation != nil {
		resp.StorageRecommendation = convertStorageRecommendationToProto(result.StorageRecommendation)
	}

	return resp
}

func convertYAMLAnalysisToProto(ya *types.YAMLAnalysisResult) *pb.YAMLAnalysisResult {
	result := &pb.YAMLAnalysisResult{
		InferredModel:    string(ya.InferredModel),
		InferredCategory: convertModelCategoryToProto(ya.InferredCategory),
		InferredFramework: string(ya.InferredFramework),
		InferredStage:    convertPipelineStageToProto(ya.InferredStage),
		InferredDataType: convertDataTypeToProto(ya.InferredDataType),
		Confidence:       ya.Confidence,
	}

	if ya.ImageAnalysis != nil {
		result.ImageAnalysis = &pb.ImageAnalysis{
			ImageName:         ya.ImageAnalysis.ImageName,
			ImageTag:          ya.ImageAnalysis.ImageTag,
			Registry:          ya.ImageAnalysis.Registry,
			DetectedFramework: string(ya.ImageAnalysis.DetectedFramework),
			DetectedModel:     string(ya.ImageAnalysis.DetectedModel),
			HasGpuSupport:     ya.ImageAnalysis.HasGPUSupport,
			BaseImage:         ya.ImageAnalysis.BaseImage,
			Confidence:        ya.ImageAnalysis.Confidence,
			Hints:             ya.ImageAnalysis.Hints,
		}
	}

	if ya.CommandAnalysis != nil {
		result.CommandAnalysis = &pb.CommandAnalysis{
			Command:          ya.CommandAnalysis.Command,
			Args:             ya.CommandAnalysis.Args,
			DetectedStage:    convertPipelineStageToProto(ya.CommandAnalysis.DetectedStage),
			DetectedModel:    string(ya.CommandAnalysis.DetectedModel),
			DetectedDataType: convertDataTypeToProto(ya.CommandAnalysis.DetectedDataType),
			BatchSize:        int32(ya.CommandAnalysis.BatchSize),
			Epochs:           int32(ya.CommandAnalysis.Epochs),
			LearningRate:     ya.CommandAnalysis.LearningRate,
			ModelPath:        ya.CommandAnalysis.ModelPath,
			DataPath:         ya.CommandAnalysis.DataPath,
			OutputPath:       ya.CommandAnalysis.OutputPath,
			Confidence:       ya.CommandAnalysis.Confidence,
			Keywords:         ya.CommandAnalysis.Keywords,
		}
	}

	for _, va := range ya.VolumeAnalyses {
		result.VolumeAnalyses = append(result.VolumeAnalyses, &pb.VolumeAnalysis{
			VolumeName:      va.VolumeName,
			MountPath:       va.MountPath,
			VolumeType:      va.VolumeType,
			ReadOnly:        va.ReadOnly,
			PurposeEstimate: va.PurposeEstimate,
			EstimatedSize:   va.EstimatedSize,
			IoPattern:       convertIOPatternToProto(va.IOPattern),
			ReadWriteRatio:  va.ReadWriteRatio,
		})
	}

	if ya.ResourceAnalysis != nil {
		result.ResourceAnalysis = &pb.ResourceAnalysis{
			CpuRequest:          ya.ResourceAnalysis.CPURequest,
			CpuLimit:            ya.ResourceAnalysis.CPULimit,
			MemoryRequest:       ya.ResourceAnalysis.MemoryRequest,
			MemoryLimit:         ya.ResourceAnalysis.MemoryLimit,
			GpuRequest:          int32(ya.ResourceAnalysis.GPURequest),
			GpuType:             ya.ResourceAnalysis.GPUType,
			EstimatedIops:       ya.ResourceAnalysis.EstimatedIOPS,
			EstimatedThroughput: ya.ResourceAnalysis.EstimatedThroughput,
			IoBottleneckRisk:    ya.ResourceAnalysis.IOBottleneckRisk,
			Confidence:          ya.ResourceAnalysis.Confidence,
		}
	}

	return result
}

func convertTraceAnalysisToProto(ta *types.TraceAnalysisResult) *pb.TraceAnalysisResult {
	result := &pb.TraceAnalysisResult{
		TraceId:               ta.TraceID,
		TraceAvailable:        ta.TraceAvailable,
		DetectedModel:         string(ta.DetectedModel),
		DetectedCategory:      convertModelCategoryToProto(ta.DetectedCategory),
		DetectedFramework:     string(ta.DetectedFramework),
		DetectedStage:         convertPipelineStageToProto(ta.DetectedStage),
		DetectedIoPattern:     convertIOPatternToProto(ta.DetectedIOPattern),
		AvgCpuUsage:           ta.AvgCPUUsage,
		AvgMemoryUsage:        ta.AvgMemoryUsage,
		AvgGpuUsage:           ta.AvgGPUUsage,
		AvgReadThroughputMbps: ta.AvgReadThroughput,
		AvgWriteThroughputMbps: ta.AvgWriteThroughput,
		Confidence:            ta.Confidence,
		LastUpdatedUnix:       ta.LastUpdated.Unix(),
	}

	for _, sh := range ta.StageHistory {
		entry := &pb.StageHistoryEntry{
			Stage:           convertPipelineStageToProto(sh.Stage),
			StartTimeUnix:   sh.StartTime.Unix(),
			DurationSeconds: sh.Duration,
		}
		if sh.EndTime != nil {
			entry.EndTimeUnix = sh.EndTime.Unix()
		}
		result.StageHistory = append(result.StageHistory, entry)
	}

	return result
}

func convertModelSignatureToProto(sig *types.AIModelSignature) *pb.AIModelSignature {
	return &pb.AIModelSignature{
		ModelCategory:           convertModelCategoryToProto(sig.ModelCategory),
		ModelType:               string(sig.ModelType),
		ModelName:               sig.ModelName,
		ModelVariant:            sig.ModelVariant,
		ModelVersion:            sig.ModelVersion,
		Framework:               string(sig.Framework),
		FrameworkVersion:        sig.FrameworkVersion,
		DataType:                convertDataTypeToProto(sig.DataType),
		InputShape:              sig.InputShape,
		OutputShape:             sig.OutputShape,
		EstimatedParams:         sig.EstimatedParams,
		EstimatedFlops:          sig.EstimatedFLOPs,
		BatchSize:               int32(sig.BatchSize),
		SequenceLength:          int32(sig.SequenceLength),
		IoPattern:               convertIOPatternToProto(sig.IOPattern),
		ReadWriteRatio:          sig.ReadWriteRatio,
		EstimatedDataSize:       sig.EstimatedDataSize,
		RecommendedStorageClass: sig.RecommendedStorageClass,
		RecommendedStorageSize:  sig.RecommendedStorageSize,
		RecommendedIops:         sig.RecommendedIOPS,
		RecommendedThroughputMbps: sig.RecommendedThroughput,
		DetectionSource:         sig.DetectionSource,
		Confidence:              sig.Confidence,
		DetectedAtUnix:          sig.DetectedAt.Unix(),
	}
}

func convertModelProfileToProto(profile *types.ModelProfile) *pb.ModelProfile {
	return &pb.ModelProfile{
		ModelType:               string(profile.ModelType),
		ModelCategory:           convertModelCategoryToProto(profile.ModelCategory),
		CommonNames:             profile.CommonNames,
		Keywords:                profile.Keywords,
		ImagePatterns:           profile.ImagePatterns,
		CommandPatterns:         profile.CommandPatterns,
		TypicalDataType:         convertDataTypeToProto(profile.TypicalDataType),
		TypicalIoPattern:        convertIOPatternToProto(profile.TypicalIOPattern),
		TypicalParams:           profile.TypicalParams,
		RecommendedStorageClass: profile.RecommendedStorageClass,
		RecommendedStorageSize:  profile.RecommendedStorageSize,
		RecommendedIops:         profile.RecommendedIOPS,
		RecommendedThroughputMbps: profile.RecommendedThroughput,
		ReadWriteRatio:          profile.ReadWriteRatio,
	}
}

func convertStorageRecommendationToProto(rec *types.StorageRecommendation) *pb.StorageRecommendation {
	return &pb.StorageRecommendation{
		StorageClass:    rec.StorageClass,
		StorageSize:     rec.StorageSize,
		AccessMode:      rec.AccessMode,
		Iops:            rec.IOPS,
		ThroughputMbps:  rec.ThroughputMBps,
		CacheTier:       rec.CacheTier,
		Reasoning:       rec.Reasoning,
		AlternativeClass: rec.AlternativeClass,
	}
}

func convertModelCategoryToProto(cat types.AIModelCategory) pb.ModelCategory {
	switch cat {
	case types.ModelCategoryVision:
		return pb.ModelCategory_MODEL_CATEGORY_VISION
	case types.ModelCategoryNLP:
		return pb.ModelCategory_MODEL_CATEGORY_NLP
	case types.ModelCategoryAudio:
		return pb.ModelCategory_MODEL_CATEGORY_AUDIO
	case types.ModelCategoryMultimodal:
		return pb.ModelCategory_MODEL_CATEGORY_MULTIMODAL
	case types.ModelCategoryGenerative:
		return pb.ModelCategory_MODEL_CATEGORY_GENERATIVE
	case types.ModelCategoryRL:
		return pb.ModelCategory_MODEL_CATEGORY_REINFORCEMENT
	case types.ModelCategoryTabular:
		return pb.ModelCategory_MODEL_CATEGORY_TABULAR
	default:
		return pb.ModelCategory_MODEL_CATEGORY_UNKNOWN
	}
}

func convertProtoToModelCategory(cat pb.ModelCategory) types.AIModelCategory {
	switch cat {
	case pb.ModelCategory_MODEL_CATEGORY_VISION:
		return types.ModelCategoryVision
	case pb.ModelCategory_MODEL_CATEGORY_NLP:
		return types.ModelCategoryNLP
	case pb.ModelCategory_MODEL_CATEGORY_AUDIO:
		return types.ModelCategoryAudio
	case pb.ModelCategory_MODEL_CATEGORY_MULTIMODAL:
		return types.ModelCategoryMultimodal
	case pb.ModelCategory_MODEL_CATEGORY_GENERATIVE:
		return types.ModelCategoryGenerative
	case pb.ModelCategory_MODEL_CATEGORY_REINFORCEMENT:
		return types.ModelCategoryRL
	case pb.ModelCategory_MODEL_CATEGORY_TABULAR:
		return types.ModelCategoryTabular
	default:
		return types.ModelCategoryUnknown
	}
}

func convertPipelineStageToProto(stage types.PipelineStage) pb.PipelineStage {
	switch stage {
	case types.StagePreprocesing:
		return pb.PipelineStage_PIPELINE_STAGE_PREPROCESSING
	case types.StageTraining:
		return pb.PipelineStage_PIPELINE_STAGE_TRAINING
	case types.StageEvaluation:
		return pb.PipelineStage_PIPELINE_STAGE_EVALUATION
	case types.StageInference:
		return pb.PipelineStage_PIPELINE_STAGE_INFERENCE
	case types.StageServing:
		return pb.PipelineStage_PIPELINE_STAGE_SERVING
	case types.StageFineTuning:
		return pb.PipelineStage_PIPELINE_STAGE_FINETUNING
	default:
		return pb.PipelineStage_PIPELINE_STAGE_UNKNOWN
	}
}

func convertDataTypeToProto(dt types.DataType) pb.DataType {
	switch dt {
	case types.DataTypeImage:
		return pb.DataType_DATA_TYPE_IMAGE
	case types.DataTypeText:
		return pb.DataType_DATA_TYPE_TEXT
	case types.DataTypeAudio:
		return pb.DataType_DATA_TYPE_AUDIO
	case types.DataTypeVideo:
		return pb.DataType_DATA_TYPE_VIDEO
	case types.DataTypeTabular:
		return pb.DataType_DATA_TYPE_TABULAR
	case types.DataTypeTimeSeries:
		return pb.DataType_DATA_TYPE_TIMESERIES
	case types.DataTypeGraph:
		return pb.DataType_DATA_TYPE_GRAPH
	case types.DataTypePoint3D:
		return pb.DataType_DATA_TYPE_POINT3D
	default:
		return pb.DataType_DATA_TYPE_UNKNOWN
	}
}

func convertIOPatternToProto(pattern types.IOPattern) pb.IOPattern {
	switch pattern {
	case types.IOPatternSequentialRead:
		return pb.IOPattern_IO_PATTERN_SEQUENTIAL_READ
	case types.IOPatternRandomRead:
		return pb.IOPattern_IO_PATTERN_RANDOM_READ
	case types.IOPatternBurstWrite:
		return pb.IOPattern_IO_PATTERN_BURST_WRITE
	case types.IOPatternWriteHeavy:
		return pb.IOPattern_IO_PATTERN_WRITE_HEAVY
	case types.IOPatternDistributed:
		return pb.IOPattern_IO_PATTERN_DISTRIBUTED
	default:
		return pb.IOPattern_IO_PATTERN_BALANCED
	}
}

func parseModelCategoryString(category string) types.AIModelCategory {
	switch category {
	case "vision", "Vision", "VISION", "MODEL_CATEGORY_VISION":
		return types.ModelCategoryVision
	case "nlp", "NLP", "MODEL_CATEGORY_NLP":
		return types.ModelCategoryNLP
	case "audio", "Audio", "AUDIO", "MODEL_CATEGORY_AUDIO":
		return types.ModelCategoryAudio
	case "multimodal", "Multimodal", "MULTIMODAL", "MODEL_CATEGORY_MULTIMODAL":
		return types.ModelCategoryMultimodal
	case "generative", "Generative", "GENERATIVE", "MODEL_CATEGORY_GENERATIVE":
		return types.ModelCategoryGenerative
	case "reinforcement", "Reinforcement", "REINFORCEMENT", "rl", "RL", "MODEL_CATEGORY_REINFORCEMENT":
		return types.ModelCategoryRL
	case "tabular", "Tabular", "TABULAR", "MODEL_CATEGORY_TABULAR":
		return types.ModelCategoryTabular
	default:
		return types.ModelCategoryUnknown
	}
}

func getRecommendationByCategory(category types.AIModelCategory) *types.StorageRecommendation {
	rec := &types.StorageRecommendation{
		AccessMode: "ReadWriteOnce",
	}

	switch category {
	case types.ModelCategoryVision:
		rec.StorageClass = "high-throughput"
		rec.StorageSize = "500Gi"
		rec.IOPS = 5000
		rec.ThroughputMBps = 500
		rec.CacheTier = "nvme"
		rec.Reasoning = "Vision workloads benefit from high sequential read throughput"
	case types.ModelCategoryNLP:
		rec.StorageClass = "high-iops"
		rec.StorageSize = "200Gi"
		rec.IOPS = 8000
		rec.ThroughputMBps = 300
		rec.CacheTier = "ssd"
		rec.Reasoning = "NLP workloads benefit from high IOPS for tokenized data"
	case types.ModelCategoryAudio:
		rec.StorageClass = "high-throughput"
		rec.StorageSize = "500Gi"
		rec.IOPS = 5000
		rec.ThroughputMBps = 500
		rec.CacheTier = "nvme"
		rec.Reasoning = "Audio workloads require high throughput for streaming"
	case types.ModelCategoryMultimodal:
		rec.StorageClass = "high-throughput"
		rec.StorageSize = "1Ti"
		rec.IOPS = 8000
		rec.ThroughputMBps = 700
		rec.CacheTier = "nvme"
		rec.Reasoning = "Multimodal needs high throughput for multiple modalities"
	default:
		rec.StorageClass = "standard"
		rec.StorageSize = "200Gi"
		rec.IOPS = 3000
		rec.ThroughputMBps = 200
		rec.CacheTier = "ssd"
		rec.Reasoning = "Standard recommendation"
	}

	return rec
}
