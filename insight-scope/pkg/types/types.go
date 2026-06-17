package types

import "time"

// =====================================================
// AI Model Categories and Types
// =====================================================

// AIModelCategory represents the broad category of AI models
type AIModelCategory string

const (
	ModelCategoryVision     AIModelCategory = "vision"        // 컴퓨터 비전
	ModelCategoryNLP        AIModelCategory = "nlp"           // 자연어 처리
	ModelCategoryAudio      AIModelCategory = "audio"         // 오디오/음성
	ModelCategoryMultimodal AIModelCategory = "multimodal"    // 멀티모달
	ModelCategoryGenerative AIModelCategory = "generative"    // 생성 모델
	ModelCategoryRL         AIModelCategory = "reinforcement" // 강화학습
	ModelCategoryTabular    AIModelCategory = "tabular"       // 정형 데이터
	ModelCategoryUnknown    AIModelCategory = "unknown"
)

// AIModelType represents specific AI model architectures
type AIModelType string

const (
	// Vision Models (컴퓨터 비전)
	ModelResNet       AIModelType = "resnet"
	ModelVGG          AIModelType = "vgg"
	ModelInception    AIModelType = "inception"
	ModelEfficientNet AIModelType = "efficientnet"
	ModelViT          AIModelType = "vit"  // Vision Transformer
	ModelYOLO         AIModelType = "yolo" // Object Detection
	ModelFasterRCNN   AIModelType = "faster-rcnn"
	ModelMaskRCNN     AIModelType = "mask-rcnn"
	ModelUNet         AIModelType = "unet" // Segmentation
	ModelDeepLab      AIModelType = "deeplab"

	// NLP Models (자연어 처리)
	ModelBERT       AIModelType = "bert"
	ModelGPT        AIModelType = "gpt"
	ModelGPT2       AIModelType = "gpt2"
	ModelGPT3       AIModelType = "gpt3"
	ModelGPT4       AIModelType = "gpt4"
	ModelLLaMA      AIModelType = "llama"
	ModelT5         AIModelType = "t5"
	ModelRoBERTa    AIModelType = "roberta"
	ModelXLNet      AIModelType = "xlnet"
	ModelALBERT     AIModelType = "albert"
	ModelDistilBERT AIModelType = "distilbert"
	ModelElectra    AIModelType = "electra"
	ModelMistral    AIModelType = "mistral"
	ModelQwen       AIModelType = "qwen"
	ModelGemma      AIModelType = "gemma"

	// Audio Models (오디오)
	ModelWhisper  AIModelType = "whisper" // Speech Recognition
	ModelWav2Vec  AIModelType = "wav2vec"
	ModelHuBERT   AIModelType = "hubert"
	ModelTacotron AIModelType = "tacotron" // TTS
	ModelWaveNet  AIModelType = "wavenet"

	// Multimodal Models (멀티모달)
	ModelCLIP            AIModelType = "clip"
	ModelDALLE           AIModelType = "dalle"
	ModelStableDiffusion AIModelType = "stable-diffusion"
	ModelLLaVA           AIModelType = "llava"
	ModelFlamingo        AIModelType = "flamingo"
	ModelBlip            AIModelType = "blip"

	// Generative Models (생성 모델)
	ModelVAE         AIModelType = "vae"
	ModelGAN         AIModelType = "gan"
	ModelDiffusion   AIModelType = "diffusion"
	ModelAutoencoder AIModelType = "autoencoder"

	// Reinforcement Learning (강화학습)
	ModelDQN AIModelType = "dqn"
	ModelPPO AIModelType = "ppo"
	ModelA3C AIModelType = "a3c"
	ModelSAC AIModelType = "sac"

	// Generic
	ModelCNN         AIModelType = "cnn"
	ModelRNN         AIModelType = "rnn"
	ModelLSTM        AIModelType = "lstm"
	ModelTransformer AIModelType = "transformer"
	ModelMLP         AIModelType = "mlp"
	ModelUnknown     AIModelType = "unknown"
)

// AIFramework represents ML/DL frameworks
type AIFramework string

const (
	FrameworkPyTorch      AIFramework = "pytorch"
	FrameworkTensorFlow   AIFramework = "tensorflow"
	FrameworkKeras        AIFramework = "keras"
	FrameworkJAX          AIFramework = "jax"
	FrameworkONNX         AIFramework = "onnx"
	FrameworkHuggingFace  AIFramework = "huggingface"
	FrameworkMXNet        AIFramework = "mxnet"
	FrameworkPaddlePaddle AIFramework = "paddlepaddle"
	FrameworkScikit       AIFramework = "scikit-learn"
	FrameworkXGBoost      AIFramework = "xgboost"
	FrameworkLightGBM     AIFramework = "lightgbm"
	FrameworkUnknown      AIFramework = "unknown"
)

// PipelineStage represents ML pipeline stages
type PipelineStage string

const (
	StagePreprocesing PipelineStage = "preprocessing"
	StageTraining     PipelineStage = "training"
	StageEvaluation   PipelineStage = "evaluation"
	StageInference    PipelineStage = "inference"
	StageServing      PipelineStage = "serving"
	StageFineTuning   PipelineStage = "finetuning"
	StageUnknown      PipelineStage = "unknown"
)

// DataType represents the type of data being processed
type DataType string

const (
	DataTypeImage      DataType = "image"
	DataTypeText       DataType = "text"
	DataTypeAudio      DataType = "audio"
	DataTypeVideo      DataType = "video"
	DataTypeTabular    DataType = "tabular"
	DataTypeTimeSeries DataType = "timeseries"
	DataTypeGraph      DataType = "graph"
	DataTypePoint3D    DataType = "point3d"
	DataTypeUnknown    DataType = "unknown"
)

// IOPattern represents I/O access patterns
type IOPattern string

const (
	IOPatternSequentialRead IOPattern = "sequential_read"
	IOPatternRandomRead     IOPattern = "random_read"
	IOPatternBurstWrite     IOPattern = "burst_write"
	IOPatternBalanced       IOPattern = "balanced"
	IOPatternWriteHeavy     IOPattern = "write_heavy"
	IOPatternDistributed    IOPattern = "distributed"
)

// =====================================================
// YAML Analysis Types
// =====================================================

// YAMLAnalysisRequest represents a request to analyze a Pod manifest
type YAMLAnalysisRequest struct {
	PodYAML   string `json:"pod_yaml,omitempty"` // Raw YAML string
	PodName   string `json:"pod_name,omitempty"` // Or existing pod name
	Namespace string `json:"namespace,omitempty"`
}

// ImageAnalysis represents container image analysis results
type ImageAnalysis struct {
	ImageName         string      `json:"image_name"`
	ImageTag          string      `json:"image_tag"`
	Registry          string      `json:"registry"`
	DetectedFramework AIFramework `json:"detected_framework"`
	DetectedModel     AIModelType `json:"detected_model,omitempty"`
	HasGPUSupport     bool        `json:"has_gpu_support"`
	BaseImage         string      `json:"base_image,omitempty"` // e.g., pytorch, tensorflow
	Confidence        float64     `json:"confidence"`
	Hints             []string    `json:"hints,omitempty"`
}

// CommandAnalysis represents container command/args analysis results
type CommandAnalysis struct {
	Command          []string      `json:"command"`
	Args             []string      `json:"args"`
	DetectedStage    PipelineStage `json:"detected_stage"`
	DetectedModel    AIModelType   `json:"detected_model,omitempty"`
	DetectedDataType DataType      `json:"detected_data_type,omitempty"`
	BatchSize        int           `json:"batch_size,omitempty"`
	Epochs           int           `json:"epochs,omitempty"`
	LearningRate     float64       `json:"learning_rate,omitempty"`
	ModelPath        string        `json:"model_path,omitempty"`
	DataPath         string        `json:"data_path,omitempty"`
	OutputPath       string        `json:"output_path,omitempty"`
	Confidence       float64       `json:"confidence"`
	Keywords         []string      `json:"keywords,omitempty"`
}

// VolumeAnalysis represents volume mount analysis results
type VolumeAnalysis struct {
	VolumeName      string    `json:"volume_name"`
	MountPath       string    `json:"mount_path"`
	VolumeType      string    `json:"volume_type"` // PVC, ConfigMap, EmptyDir, etc.
	ReadOnly        bool      `json:"read_only"`
	PurposeEstimate string    `json:"purpose_estimate"` // data, model, checkpoint, output
	EstimatedSize   string    `json:"estimated_size,omitempty"`
	IOPattern       IOPattern `json:"io_pattern"`
	ReadWriteRatio  float64   `json:"read_write_ratio"` // 0.0 (all write) ~ 1.0 (all read)
}

// ResourceAnalysis represents resource request/limit analysis
type ResourceAnalysis struct {
	CPURequest          string  `json:"cpu_request"`
	CPULimit            string  `json:"cpu_limit"`
	MemoryRequest       string  `json:"memory_request"`
	MemoryLimit         string  `json:"memory_limit"`
	GPURequest          int     `json:"gpu_request"`
	GPUType             string  `json:"gpu_type,omitempty"` // nvidia.com/gpu, amd.com/gpu
	EstimatedIOPS       int64   `json:"estimated_iops"`
	EstimatedThroughput int64   `json:"estimated_throughput_mbps"`
	IOBottleneckRisk    string  `json:"io_bottleneck_risk"` // low, medium, high
	Confidence          float64 `json:"confidence"`
}

// AnnotationAnalysis represents label/annotation analysis
type AnnotationAnalysis struct {
	Labels           map[string]string `json:"labels"`
	Annotations      map[string]string `json:"annotations"`
	ExplicitWorkload string            `json:"explicit_workload,omitempty"`
	ExplicitModel    string            `json:"explicit_model,omitempty"`
	ExplicitStage    string            `json:"explicit_stage,omitempty"`
	KubeflowJob      string            `json:"kubeflow_job,omitempty"`
	VolcanoJob       string            `json:"volcano_job,omitempty"`
	HasInsightTrace  bool              `json:"has_insight_trace"`
}

// =====================================================
// AI Model Detection Types
// =====================================================

// AIModelSignature represents the detected AI model signature
type AIModelSignature struct {
	// Primary detection
	ModelCategory AIModelCategory `json:"model_category"`
	ModelType     AIModelType     `json:"model_type"`
	ModelName     string          `json:"model_name,omitempty"`    // e.g., "bert-base-uncased"
	ModelVariant  string          `json:"model_variant,omitempty"` // e.g., "large", "xl"
	ModelVersion  string          `json:"model_version,omitempty"`

	// Framework
	Framework        AIFramework `json:"framework"`
	FrameworkVersion string      `json:"framework_version,omitempty"`

	// Data characteristics
	DataType    DataType `json:"data_type"`
	InputShape  string   `json:"input_shape,omitempty"` // e.g., "224x224x3"
	OutputShape string   `json:"output_shape,omitempty"`

	// Training characteristics
	EstimatedParams int64 `json:"estimated_params,omitempty"` // Model parameters
	EstimatedFLOPs  int64 `json:"estimated_flops,omitempty"`
	BatchSize       int   `json:"batch_size,omitempty"`
	SequenceLength  int   `json:"sequence_length,omitempty"` // For NLP

	// I/O characteristics
	IOPattern         IOPattern `json:"io_pattern"`
	ReadWriteRatio    float64   `json:"read_write_ratio"`
	EstimatedDataSize string    `json:"estimated_data_size,omitempty"` // Dataset size

	// Storage recommendations
	RecommendedStorageClass string `json:"recommended_storage_class"`
	RecommendedStorageSize  string `json:"recommended_storage_size"`
	RecommendedIOPS         int64  `json:"recommended_iops"`
	RecommendedThroughput   int64  `json:"recommended_throughput_mbps"`

	// Detection metadata
	DetectionSource string    `json:"detection_source"` // yaml, trace, combined
	Confidence      float64   `json:"confidence"`       // 0.0 ~ 1.0
	DetectedAt      time.Time `json:"detected_at"`
}

// =====================================================
// Combined Scope Analysis
// =====================================================

// ScopeAnalysisRequest represents a request to analyze a workload
type ScopeAnalysisRequest struct {
	// Pod identification (one of these required)
	PodYAML   string `json:"pod_yaml,omitempty"`
	PodName   string `json:"pod_name,omitempty"`
	Namespace string `json:"namespace,omitempty"`

	// Options
	IncludeTraceData bool `json:"include_trace_data"` // Fetch from Insight Trace
	WaitForTrace     bool `json:"wait_for_trace"`     // Wait for trace data if not available
}

// ScopeAnalysisResult represents the complete analysis result
type ScopeAnalysisResult struct {
	// Identification
	AnalysisID    string `json:"analysis_id"`
	PodName       string `json:"pod_name"`
	PodNamespace  string `json:"pod_namespace"`
	ContainerName string `json:"container_name,omitempty"`

	// YAML Analysis (정적 분석)
	YAMLAnalysis *YAMLAnalysisResult `json:"yaml_analysis,omitempty"`

	// Trace Analysis (동적 분석 - Insight Trace 연동)
	TraceAnalysis *TraceAnalysisResult `json:"trace_analysis,omitempty"`

	// DAG Analysis (Argo Workflow DAG 분석)
	DAGAnalysis   *DAGAnalysis   `json:"dag_analysis,omitempty"`
	ShardAnalysis *ShardAnalysis `json:"shard_analysis,omitempty"`

	// Combined AI Model Signature (통합 결과)
	ModelSignature *AIModelSignature `json:"model_signature"`

	// Pipeline stage
	CurrentStage PipelineStage `json:"current_stage"`

	// Storage Recommendations
	StorageRecommendation *StorageRecommendation `json:"storage_recommendation"`

	// Analysis metadata
	AnalyzedAt       time.Time `json:"analyzed_at"`
	AnalysisDuration float64   `json:"analysis_duration_ms"`
}

// YAMLAnalysisResult contains all YAML-based analysis results
type YAMLAnalysisResult struct {
	ImageAnalysis      *ImageAnalysis      `json:"image_analysis"`
	CommandAnalysis    *CommandAnalysis    `json:"command_analysis"`
	VolumeAnalyses     []VolumeAnalysis    `json:"volume_analyses"`
	ResourceAnalysis   *ResourceAnalysis   `json:"resource_analysis"`
	AnnotationAnalysis *AnnotationAnalysis `json:"annotation_analysis"`

	// Combined inference from YAML
	InferredModel     AIModelType     `json:"inferred_model"`
	InferredCategory  AIModelCategory `json:"inferred_category"`
	InferredFramework AIFramework     `json:"inferred_framework"`
	InferredStage     PipelineStage   `json:"inferred_stage"`
	InferredDataType  DataType        `json:"inferred_data_type"`
	Confidence        float64         `json:"confidence"`
}

// TraceAnalysisResult contains Insight Trace-based analysis results
type TraceAnalysisResult struct {
	TraceID        string `json:"trace_id"`
	TraceAvailable bool   `json:"trace_available"`

	// Runtime detected values
	DetectedModel     AIModelType     `json:"detected_model"`
	DetectedCategory  AIModelCategory `json:"detected_category"`
	DetectedFramework AIFramework     `json:"detected_framework"`
	DetectedStage     PipelineStage   `json:"detected_stage"`
	DetectedIOPattern IOPattern       `json:"detected_io_pattern"`

	// Resource usage patterns
	AvgCPUUsage        float64 `json:"avg_cpu_usage_percent"`
	AvgMemoryUsage     float64 `json:"avg_memory_usage_percent"`
	AvgGPUUsage        float64 `json:"avg_gpu_usage_percent"`
	AvgReadThroughput  float64 `json:"avg_read_throughput_mbps"`
	AvgWriteThroughput float64 `json:"avg_write_throughput_mbps"`

	// Stage history
	StageHistory  []StageHistoryEntry `json:"stage_history,omitempty"`
	ShardMetadata *ShardMetadata      `json:"shard_metadata,omitempty"`

	Confidence  float64   `json:"confidence"`
	LastUpdated time.Time `json:"last_updated"`
}

// StageHistoryEntry represents a pipeline stage entry
type StageHistoryEntry struct {
	Stage     PipelineStage `json:"stage"`
	StartTime time.Time     `json:"start_time"`
	EndTime   *time.Time    `json:"end_time,omitempty"`
	Duration  float64       `json:"duration_seconds,omitempty"`
}

// ShardMetadata는 trace가 전달한 shard 입력 스캔 메타이다.
type ShardMetadata struct {
	ShardCount     int      `json:"shard_count"`
	ShardIndex     int      `json:"shard_index"`
	ShardPath      string   `json:"shard_path"`
	ShardSizeBytes int64    `json:"shard_size_bytes"`
	ShardPaths     []string `json:"shard_paths,omitempty"`
	ShardEntries   []string `json:"shard_entries,omitempty"`
	ShardSource    string   `json:"shard_source,omitempty"`
	ShardScanError string   `json:"shard_scan_error,omitempty"`
	TarHeaderCount int      `json:"tar_header_count,omitempty"`
}

// ShardAnalysis는 shard 단위 분석 결과를 나타낸다.
type ShardAnalysis struct {
	ShardCount      int     `json:"shard_count"`
	ShardIndex      int     `json:"shard_index"`
	ShardPath       string  `json:"shard_path"`
	ShardSizeBytes  int64   `json:"shard_size_bytes"`
	RelativeWeight  float64 `json:"relative_weight"`
	DistributionKey string  `json:"distribution_key"`
	Source          string  `json:"source,omitempty"`
	PathSampleCount int     `json:"path_sample_count,omitempty"`
	TarHeaderCount  int     `json:"tar_header_count,omitempty"`
	ScanError       string  `json:"scan_error,omitempty"`
}

// StorageRecommendation represents storage recommendations
type StorageRecommendation struct {
	StorageClass     string `json:"storage_class"`
	StorageSize      string `json:"storage_size"`
	AccessMode       string `json:"access_mode"` // ReadWriteOnce, ReadWriteMany
	IOPS             int64  `json:"iops"`
	ThroughputMBps   int64  `json:"throughput_mbps"`
	CacheTier        string `json:"cache_tier,omitempty"` // nvme, ssd, hdd
	Reasoning        string `json:"reasoning"`
	AlternativeClass string `json:"alternative_class,omitempty"`
}

// =====================================================
// Model Knowledge Base Types
// =====================================================

// ModelProfile represents a known AI model profile
type ModelProfile struct {
	ModelType       AIModelType     `json:"model_type"`
	ModelCategory   AIModelCategory `json:"model_category"`
	CommonNames     []string        `json:"common_names"`     // Variations of the name
	Keywords        []string        `json:"keywords"`         // Detection keywords
	ImagePatterns   []string        `json:"image_patterns"`   // Container image patterns
	CommandPatterns []string        `json:"command_patterns"` // Command line patterns

	// Typical characteristics
	TypicalDataType  DataType  `json:"typical_data_type"`
	TypicalIOPattern IOPattern `json:"typical_io_pattern"`
	TypicalParams    int64     `json:"typical_params,omitempty"`

	// Resource recommendations
	RecommendedStorageClass string  `json:"recommended_storage_class"`
	RecommendedStorageSize  string  `json:"recommended_storage_size"`
	RecommendedIOPS         int64   `json:"recommended_iops"`
	RecommendedThroughput   int64   `json:"recommended_throughput_mbps"`
	ReadWriteRatio          float64 `json:"read_write_ratio"`
}

// =====================================================
// Argo Workflow DAG Analysis Types
// =====================================================

// DAGAnalysis represents analysis of Argo Workflow DAG structure
type DAGAnalysis struct {
	WorkflowName      string          `json:"workflow_name"`
	WorkflowNamespace string          `json:"workflow_namespace"`
	TotalSteps        int             `json:"total_steps"`
	CurrentStep       string          `json:"current_step"`
	CurrentStepIndex  int             `json:"current_step_index"`
	Steps             []DAGStep       `json:"steps"`
	DataFlow          []DataFlowEdge  `json:"data_flow,omitempty"`
	ExecutionHistory  []StepExecution `json:"execution_history,omitempty"`

	// Inferred characteristics from DAG
	InferredPipelineType string    `json:"inferred_pipeline_type"` // training, inference, etl
	InferredDataPattern  IOPattern `json:"inferred_data_pattern"`  // based on DAG structure
	EstimatedTotalIOGB   float64   `json:"estimated_total_io_gb"`
	ParallelismLevel     int       `json:"parallelism_level"`
}

// DAGStep represents a single step in the DAG
type DAGStep struct {
	Name          string        `json:"name"`
	Template      string        `json:"template"`
	Dependencies  []string      `json:"dependencies,omitempty"`
	Phase         string        `json:"phase"`      // Pending, Running, Succeeded, Failed
	StepType      PipelineStage `json:"step_type"`  // preprocessing, training, evaluation
	IOPattern     IOPattern     `json:"io_pattern"` // inferred I/O pattern for this step
	EstimatedIOGB float64       `json:"estimated_io_gb"`
}

// DataFlowEdge represents data flow between steps
type DataFlowEdge struct {
	FromStep        string  `json:"from_step"`
	ToStep          string  `json:"to_step"`
	DataType        string  `json:"data_type,omitempty"` // model, dataset, checkpoint
	EstimatedSizeGB float64 `json:"estimated_size_gb,omitempty"`
}

// StepExecution represents execution history of a step
type StepExecution struct {
	StepName      string             `json:"step_name"`
	StartTime     string             `json:"start_time,omitempty"`
	EndTime       string             `json:"end_time,omitempty"`
	DurationSec   float64            `json:"duration_sec,omitempty"`
	Status        string             `json:"status"`
	ResourceUsage *StepResourceUsage `json:"resource_usage,omitempty"`
}

// StepResourceUsage represents resource usage during step execution
type StepResourceUsage struct {
	AvgCPUPercent    float64 `json:"avg_cpu_percent"`
	AvgMemoryPercent float64 `json:"avg_memory_percent"`
	AvgGPUPercent    float64 `json:"avg_gpu_percent,omitempty"`
	TotalReadGB      float64 `json:"total_read_gb"`
	TotalWriteGB     float64 `json:"total_write_gb"`
}
