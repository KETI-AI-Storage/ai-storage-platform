package analyzer

import (
	"regexp"
	"strconv"
	"strings"

	"insight-scope/pkg/types"

	corev1 "k8s.io/api/core/v1"
)

// YAMLAnalyzer analyzes Pod manifests to extract AI workload characteristics
type YAMLAnalyzer struct {
	imageAnalyzer      *ImageAnalyzer
	commandAnalyzer    *CommandAnalyzer
	volumeAnalyzer     *VolumeAnalyzer
	resourceAnalyzer   *ResourceAnalyzer
	annotationAnalyzer *AnnotationAnalyzer
}

// NewYAMLAnalyzer creates a new YAML analyzer
func NewYAMLAnalyzer() *YAMLAnalyzer {
	return &YAMLAnalyzer{
		imageAnalyzer:      NewImageAnalyzer(),
		commandAnalyzer:    NewCommandAnalyzer(),
		volumeAnalyzer:     NewVolumeAnalyzer(),
		resourceAnalyzer:   NewResourceAnalyzer(),
		annotationAnalyzer: NewAnnotationAnalyzer(),
	}
}

// AnalyzePod analyzes a Pod spec and returns comprehensive results
func (ya *YAMLAnalyzer) AnalyzePod(pod *corev1.Pod) *types.YAMLAnalysisResult {
	result := &types.YAMLAnalysisResult{
		VolumeAnalyses: make([]types.VolumeAnalysis, 0),
	}
	mainContainer := ya.findMainContainer(pod)
	if mainContainer == nil {
		return result
	}
	result.ImageAnalysis = ya.imageAnalyzer.Analyze(mainContainer.Image)
	result.CommandAnalysis = ya.commandAnalyzer.Analyze(mainContainer.Command, mainContainer.Args, mainContainer.Env)
	for _, vm := range mainContainer.VolumeMounts {
		// Find corresponding volume
		var volume *corev1.Volume
		for i := range pod.Spec.Volumes {
			if pod.Spec.Volumes[i].Name == vm.Name {
				volume = &pod.Spec.Volumes[i]
				break
			}
		}
		analysis := ya.volumeAnalyzer.Analyze(&vm, volume)
		result.VolumeAnalyses = append(result.VolumeAnalyses, *analysis)
	}
	result.ResourceAnalysis = ya.resourceAnalyzer.Analyze(&mainContainer.Resources)
	result.AnnotationAnalysis = ya.annotationAnalyzer.Analyze(pod.Labels, pod.Annotations)
	ya.combineInferences(result)

	return result
}

// findMainContainer finds the main workload container (not sidecar)
func (ya *YAMLAnalyzer) findMainContainer(pod *corev1.Pod) *corev1.Container {
	for i := range pod.Spec.Containers {
		c := &pod.Spec.Containers[i]
		// Skip known sidecars
		if strings.Contains(c.Name, "sidecar") ||
			strings.Contains(c.Name, "insight-trace") ||
			strings.Contains(c.Name, "istio") ||
			strings.Contains(c.Name, "envoy") {
			continue
		}
		return c
	}

	// Fallback to first container
	if len(pod.Spec.Containers) > 0 {
		return &pod.Spec.Containers[0]
	}
	return nil
}

func (ya *YAMLAnalyzer) combineInferences(result *types.YAMLAnalysisResult) {
	var confidence float64
	var confidenceCount int
	if result.ImageAnalysis != nil && result.ImageAnalysis.DetectedFramework != types.FrameworkUnknown {
		result.InferredFramework = result.ImageAnalysis.DetectedFramework
		confidence += result.ImageAnalysis.Confidence
		confidenceCount++
	}
	if result.AnnotationAnalysis != nil && result.AnnotationAnalysis.ExplicitModel != "" {
		result.InferredModel = types.AIModelType(result.AnnotationAnalysis.ExplicitModel)
		confidence += 1.0
		confidenceCount++
	} else if result.CommandAnalysis != nil && result.CommandAnalysis.DetectedModel != types.ModelUnknown {
		result.InferredModel = result.CommandAnalysis.DetectedModel
		confidence += result.CommandAnalysis.Confidence
		confidenceCount++
	} else if result.ImageAnalysis != nil && result.ImageAnalysis.DetectedModel != types.ModelUnknown {
		result.InferredModel = result.ImageAnalysis.DetectedModel
		confidence += result.ImageAnalysis.Confidence
		confidenceCount++
	} else {
		result.InferredModel = types.ModelUnknown
	}
	result.InferredCategory = ya.inferCategoryFromModel(result.InferredModel)
	if result.AnnotationAnalysis != nil && result.AnnotationAnalysis.ExplicitStage != "" {
		result.InferredStage = types.PipelineStage(result.AnnotationAnalysis.ExplicitStage)
	} else if result.CommandAnalysis != nil && result.CommandAnalysis.DetectedStage != types.StageUnknown {
		result.InferredStage = result.CommandAnalysis.DetectedStage
		confidence += result.CommandAnalysis.Confidence
		confidenceCount++
	} else {
		result.InferredStage = types.StageUnknown
	}
	if result.CommandAnalysis != nil && result.CommandAnalysis.DetectedDataType != types.DataTypeUnknown {
		result.InferredDataType = result.CommandAnalysis.DetectedDataType
	} else {
		result.InferredDataType = ya.inferDataTypeFromCategory(result.InferredCategory)
	}
	if confidenceCount > 0 {
		result.Confidence = confidence / float64(confidenceCount)
	}
}

// todo: 모델들에 대한 정의를 지속적으로 업데이트 필요.
func (ya *YAMLAnalyzer) inferCategoryFromModel(model types.AIModelType) types.AIModelCategory {
	visionModels := map[types.AIModelType]bool{
		types.ModelResNet: true, types.ModelVGG: true, types.ModelInception: true,
		types.ModelEfficientNet: true, types.ModelViT: true, types.ModelYOLO: true,
		types.ModelFasterRCNN: true, types.ModelMaskRCNN: true, types.ModelUNet: true,
		types.ModelDeepLab: true, types.ModelCNN: true,
	}

	nlpModels := map[types.AIModelType]bool{
		types.ModelBERT: true, types.ModelGPT: true, types.ModelGPT2: true,
		types.ModelGPT3: true, types.ModelGPT4: true, types.ModelLLaMA: true,
		types.ModelT5: true, types.ModelRoBERTa: true, types.ModelXLNet: true,
		types.ModelALBERT: true, types.ModelDistilBERT: true, types.ModelElectra: true,
		types.ModelMistral: true, types.ModelQwen: true, types.ModelGemma: true,
		types.ModelTransformer: true, types.ModelRNN: true, types.ModelLSTM: true,
	}

	audioModels := map[types.AIModelType]bool{
		types.ModelWhisper: true, types.ModelWav2Vec: true, types.ModelHuBERT: true,
		types.ModelTacotron: true, types.ModelWaveNet: true,
	}

	multimodalModels := map[types.AIModelType]bool{
		types.ModelCLIP: true, types.ModelDALLE: true, types.ModelStableDiffusion: true,
		types.ModelLLaVA: true, types.ModelFlamingo: true, types.ModelBlip: true,
	}

	generativeModels := map[types.AIModelType]bool{
		types.ModelVAE: true, types.ModelGAN: true, types.ModelDiffusion: true,
		types.ModelAutoencoder: true,
	}

	rlModels := map[types.AIModelType]bool{
		types.ModelDQN: true, types.ModelPPO: true, types.ModelA3C: true,
		types.ModelSAC: true,
	}

	if visionModels[model] {
		return types.ModelCategoryVision
	}
	if nlpModels[model] {
		return types.ModelCategoryNLP
	}
	if audioModels[model] {
		return types.ModelCategoryAudio
	}
	if multimodalModels[model] {
		return types.ModelCategoryMultimodal
	}
	if generativeModels[model] {
		return types.ModelCategoryGenerative
	}
	if rlModels[model] {
		return types.ModelCategoryRL
	}

	return types.ModelCategoryUnknown
}

// inferDataTypeFromCategory infers data type from model category
func (ya *YAMLAnalyzer) inferDataTypeFromCategory(category types.AIModelCategory) types.DataType {
	switch category {
	case types.ModelCategoryVision:
		return types.DataTypeImage
	case types.ModelCategoryNLP:
		return types.DataTypeText
	case types.ModelCategoryAudio:
		return types.DataTypeAudio
	case types.ModelCategoryMultimodal:
		return types.DataTypeImage // Primary is often image
	default:
		return types.DataTypeUnknown
	}
}

// =====================================================
// Image Analyzer
// =====================================================

// ImageAnalyzer analyzes container images
type ImageAnalyzer struct {
	frameworkPatterns map[types.AIFramework][]string
	modelPatterns     map[types.AIModelType][]string
}

// NewImageAnalyzer creates a new image analyzer
func NewImageAnalyzer() *ImageAnalyzer {
	ia := &ImageAnalyzer{
		frameworkPatterns: make(map[types.AIFramework][]string),
		modelPatterns:     make(map[types.AIModelType][]string),
	}
	ia.initPatterns()
	return ia
}

func (ia *ImageAnalyzer) initPatterns() {
	// Framework patterns
	ia.frameworkPatterns[types.FrameworkPyTorch] = []string{
		"pytorch", "torch", "torchserve", "torchvision",
	}
	ia.frameworkPatterns[types.FrameworkTensorFlow] = []string{
		"tensorflow", "tf-", "tfserving", "tf2",
	}
	ia.frameworkPatterns[types.FrameworkHuggingFace] = []string{
		"huggingface", "transformers", "hf-",
	}
	ia.frameworkPatterns[types.FrameworkJAX] = []string{
		"jax", "flax", "optax",
	}
	ia.frameworkPatterns[types.FrameworkONNX] = []string{
		"onnx", "onnxruntime",
	}
	ia.frameworkPatterns[types.FrameworkKeras] = []string{
		"keras",
	}

	// Model patterns
	ia.modelPatterns[types.ModelBERT] = []string{"bert", "roberta", "distilbert", "albert"}
	ia.modelPatterns[types.ModelGPT] = []string{"gpt", "gpt2", "gpt-2", "gpt3", "gpt-3", "gpt4", "gpt-4"}
	ia.modelPatterns[types.ModelLLaMA] = []string{"llama", "llama2", "llama-2", "codellama"}
	ia.modelPatterns[types.ModelMistral] = []string{"mistral", "mixtral"}
	ia.modelPatterns[types.ModelT5] = []string{"t5", "flan-t5", "mt5"}
	ia.modelPatterns[types.ModelWhisper] = []string{"whisper", "openai-whisper"}
	ia.modelPatterns[types.ModelStableDiffusion] = []string{"stable-diffusion", "stablediffusion", "sd-"}
	ia.modelPatterns[types.ModelCLIP] = []string{"clip", "openclip"}
	ia.modelPatterns[types.ModelYOLO] = []string{"yolo", "yolov5", "yolov8", "ultralytics"}
	ia.modelPatterns[types.ModelResNet] = []string{"resnet", "resnet50", "resnet101"}
	ia.modelPatterns[types.ModelViT] = []string{"vit", "vision-transformer", "deit"}
}

// Analyze analyzes a container image
func (ia *ImageAnalyzer) Analyze(image string) *types.ImageAnalysis {
	result := &types.ImageAnalysis{
		DetectedFramework: types.FrameworkUnknown,
		DetectedModel:     types.ModelUnknown,
		Confidence:        0.3, // Base confidence
	}

	// Parse image name
	parts := strings.Split(image, "/")
	if len(parts) > 1 {
		result.Registry = strings.Join(parts[:len(parts)-1], "/")
		image = parts[len(parts)-1]
	}

	// Parse tag
	tagParts := strings.Split(image, ":")
	result.ImageName = tagParts[0]
	if len(tagParts) > 1 {
		result.ImageTag = tagParts[1]
	}

	imageLower := strings.ToLower(image)

	// Detect framework
	for framework, patterns := range ia.frameworkPatterns {
		for _, pattern := range patterns {
			if strings.Contains(imageLower, pattern) {
				result.DetectedFramework = framework
				result.Confidence = 0.8
				result.Hints = append(result.Hints, "framework:"+pattern)
				break
			}
		}
	}

	// Detect model
	for model, patterns := range ia.modelPatterns {
		for _, pattern := range patterns {
			if strings.Contains(imageLower, pattern) {
				result.DetectedModel = model
				result.Confidence = 0.85
				result.Hints = append(result.Hints, "model:"+pattern)
				break
			}
		}
	}

	// Check for GPU support
	if strings.Contains(imageLower, "cuda") ||
		strings.Contains(imageLower, "gpu") ||
		strings.Contains(imageLower, "nvidia") {
		result.HasGPUSupport = true
	}

	// Detect base image
	baseImages := []string{"pytorch", "tensorflow", "nvidia", "python", "ubuntu"}
	for _, base := range baseImages {
		if strings.Contains(imageLower, base) {
			result.BaseImage = base
			break
		}
	}

	return result
}

// =====================================================
// Command Analyzer
// =====================================================

// CommandAnalyzer analyzes container commands and arguments
type CommandAnalyzer struct {
	stageKeywords map[types.PipelineStage][]string
	modelKeywords map[types.AIModelType][]string
	dataKeywords  map[types.DataType][]string
}

// NewCommandAnalyzer creates a new command analyzer
func NewCommandAnalyzer() *CommandAnalyzer {
	ca := &CommandAnalyzer{
		stageKeywords: make(map[types.PipelineStage][]string),
		modelKeywords: make(map[types.AIModelType][]string),
		dataKeywords:  make(map[types.DataType][]string),
	}
	ca.initKeywords()
	return ca
}

func (ca *CommandAnalyzer) initKeywords() {
	// Stage keywords
	ca.stageKeywords[types.StagePreprocesing] = []string{
		"preprocess", "preprocessing", "prepare", "etl", "transform",
		"augment", "resize", "normalize", "tokenize", "encode",
	}
	ca.stageKeywords[types.StageTraining] = []string{
		"train", "training", "fit", "learn", "finetune", "fine-tune",
		"torchrun", "deepspeed", "accelerate", "trainer",
	}
	ca.stageKeywords[types.StageEvaluation] = []string{
		"eval", "evaluate", "evaluation", "test", "validate", "validation",
		"benchmark", "score",
	}
	ca.stageKeywords[types.StageInference] = []string{
		"infer", "inference", "predict", "serve", "serving",
		"triton", "torchserve", "tfserving",
	}

	// Model keywords
	ca.modelKeywords[types.ModelBERT] = []string{"bert", "roberta", "distilbert"}
	ca.modelKeywords[types.ModelGPT] = []string{"gpt", "gpt2", "gpt-2", "openai"}
	ca.modelKeywords[types.ModelLLaMA] = []string{"llama", "meta-llama"}
	ca.modelKeywords[types.ModelT5] = []string{"t5", "flan"}
	ca.modelKeywords[types.ModelWhisper] = []string{"whisper"}
	ca.modelKeywords[types.ModelYOLO] = []string{"yolo", "detect", "ultralytics"}
	ca.modelKeywords[types.ModelResNet] = []string{"resnet", "imagenet"}
	ca.modelKeywords[types.ModelStableDiffusion] = []string{"diffusion", "stable-diffusion", "sdxl"}
	ca.modelKeywords[types.ModelViT] = []string{"vit", "vision_transformer"}

	// Data type keywords
	ca.dataKeywords[types.DataTypeImage] = []string{
		"image", "img", "jpeg", "png", "jpg", "cv2", "pillow", "opencv",
		"imagenet", "coco", "cifar", "mnist",
	}
	ca.dataKeywords[types.DataTypeText] = []string{
		"text", "nlp", "tokenize", "vocab", "sentence", "document",
		"squad", "glue", "wikitext",
	}
	ca.dataKeywords[types.DataTypeAudio] = []string{
		"audio", "wav", "mp3", "speech", "asr", "tts", "librosa",
	}
	ca.dataKeywords[types.DataTypeVideo] = []string{
		"video", "mp4", "avi", "frame", "ffmpeg",
	}
}

// Analyze analyzes command and arguments
func (ca *CommandAnalyzer) Analyze(command, args []string, env []corev1.EnvVar) *types.CommandAnalysis {
	result := &types.CommandAnalysis{
		Command:          command,
		Args:             args,
		DetectedStage:    types.StageUnknown,
		DetectedModel:    types.ModelUnknown,
		DetectedDataType: types.DataTypeUnknown,
		Confidence:       0.3,
	}

	// Combine command and args for analysis
	fullCmd := strings.ToLower(strings.Join(append(command, args...), " "))

	// Detect stage
	for stage, keywords := range ca.stageKeywords {
		for _, kw := range keywords {
			if strings.Contains(fullCmd, kw) {
				result.DetectedStage = stage
				result.Keywords = append(result.Keywords, "stage:"+kw)
				result.Confidence = 0.7
				break
			}
		}
	}

	// Detect model
	for model, keywords := range ca.modelKeywords {
		for _, kw := range keywords {
			if strings.Contains(fullCmd, kw) {
				result.DetectedModel = model
				result.Keywords = append(result.Keywords, "model:"+kw)
				result.Confidence = 0.75
				break
			}
		}
	}

	// Detect data type
	for dataType, keywords := range ca.dataKeywords {
		for _, kw := range keywords {
			if strings.Contains(fullCmd, kw) {
				result.DetectedDataType = dataType
				result.Keywords = append(result.Keywords, "data:"+kw)
				break
			}
		}
	}

	// Extract parameters
	ca.extractParameters(fullCmd, result)

	// Check environment variables
	ca.analyzeEnvVars(env, result)

	return result
}

// extractParameters extracts training parameters from command
func (ca *CommandAnalyzer) extractParameters(cmd string, result *types.CommandAnalysis) {
	// Batch size patterns
	batchPatterns := []string{
		`--batch[_-]?size[=\s]+(\d+)`,
		`-b\s+(\d+)`,
		`batch[=\s]+(\d+)`,
	}
	for _, pattern := range batchPatterns {
		re := regexp.MustCompile(pattern)
		if matches := re.FindStringSubmatch(cmd); len(matches) > 1 {
			result.BatchSize, _ = strconv.Atoi(matches[1])
			break
		}
	}

	// Epochs patterns
	epochPatterns := []string{
		`--epochs?[=\s]+(\d+)`,
		`-e\s+(\d+)`,
		`num[_-]?epochs?[=\s]+(\d+)`,
	}
	for _, pattern := range epochPatterns {
		re := regexp.MustCompile(pattern)
		if matches := re.FindStringSubmatch(cmd); len(matches) > 1 {
			result.Epochs, _ = strconv.Atoi(matches[1])
			break
		}
	}

	// Learning rate patterns
	lrPatterns := []string{
		`--lr[=\s]+([\d.e-]+)`,
		`--learning[_-]?rate[=\s]+([\d.e-]+)`,
	}
	for _, pattern := range lrPatterns {
		re := regexp.MustCompile(pattern)
		if matches := re.FindStringSubmatch(cmd); len(matches) > 1 {
			result.LearningRate, _ = strconv.ParseFloat(matches[1], 64)
			break
		}
	}

	// Model path
	modelPathPatterns := []string{
		`--model[_-]?path[=\s]+([^\s]+)`,
		`--checkpoint[=\s]+([^\s]+)`,
		`--pretrained[=\s]+([^\s]+)`,
	}
	for _, pattern := range modelPathPatterns {
		re := regexp.MustCompile(pattern)
		if matches := re.FindStringSubmatch(cmd); len(matches) > 1 {
			result.ModelPath = matches[1]
			break
		}
	}

	// Data path
	dataPathPatterns := []string{
		`--data[_-]?path[=\s]+([^\s]+)`,
		`--data[_-]?dir[=\s]+([^\s]+)`,
		`--dataset[=\s]+([^\s]+)`,
	}
	for _, pattern := range dataPathPatterns {
		re := regexp.MustCompile(pattern)
		if matches := re.FindStringSubmatch(cmd); len(matches) > 1 {
			result.DataPath = matches[1]
			break
		}
	}

	// Output path
	outputPathPatterns := []string{
		`--output[_-]?path[=\s]+([^\s]+)`,
		`--output[_-]?dir[=\s]+([^\s]+)`,
		`--save[_-]?path[=\s]+([^\s]+)`,
	}
	for _, pattern := range outputPathPatterns {
		re := regexp.MustCompile(pattern)
		if matches := re.FindStringSubmatch(cmd); len(matches) > 1 {
			result.OutputPath = matches[1]
			break
		}
	}
}

// analyzeEnvVars analyzes environment variables
func (ca *CommandAnalyzer) analyzeEnvVars(env []corev1.EnvVar, result *types.CommandAnalysis) {
	for _, e := range env {
		nameLower := strings.ToLower(e.Name)
		valueLower := strings.ToLower(e.Value)

		// Check for explicit hints
		if nameLower == "workload_type" || nameLower == "model_type" {
			for model, keywords := range ca.modelKeywords {
				for _, kw := range keywords {
					if strings.Contains(valueLower, kw) {
						result.DetectedModel = model
						result.Confidence = 0.9 // High confidence for explicit env
						break
					}
				}
			}
		}

		if nameLower == "pipeline_stage" {
			for stage, keywords := range ca.stageKeywords {
				for _, kw := range keywords {
					if strings.Contains(valueLower, kw) {
						result.DetectedStage = stage
						result.Confidence = 0.9
						break
					}
				}
			}
		}
	}
}
