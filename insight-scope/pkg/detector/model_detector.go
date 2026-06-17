package detector

import (
	"strings"
	"time"

	"insight-scope/pkg/types"
)

// ModelDetector detects AI model types from various sources
type ModelDetector struct {
	knowledgeBase map[types.AIModelType]*types.ModelProfile
}

// NewModelDetector creates a new model detector
func NewModelDetector() *ModelDetector {
	md := &ModelDetector{
		knowledgeBase: make(map[types.AIModelType]*types.ModelProfile),
	}
	md.initKnowledgeBase()
	return md
}

// initKnowledgeBase initializes the AI model knowledge base
func (md *ModelDetector) initKnowledgeBase() {
	// =====================================================
	// Vision Models (컴퓨터 비전)
	// =====================================================

	md.knowledgeBase[types.ModelResNet] = &types.ModelProfile{
		ModelType:        types.ModelResNet,
		ModelCategory:    types.ModelCategoryVision,
		CommonNames:      []string{"resnet", "resnet18", "resnet34", "resnet50", "resnet101", "resnet152"},
		Keywords:         []string{"resnet", "residual", "imagenet", "classification"},
		ImagePatterns:    []string{"resnet", "torchvision"},
		CommandPatterns:  []string{"resnet", "--arch resnet", "-a resnet"},
		TypicalDataType:  types.DataTypeImage,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    25_000_000, // ResNet50
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "200Gi",
		RecommendedIOPS:         5000,
		RecommendedThroughput:   500,
		ReadWriteRatio:          0.9,
	}

	md.knowledgeBase[types.ModelYOLO] = &types.ModelProfile{
		ModelType:        types.ModelYOLO,
		ModelCategory:    types.ModelCategoryVision,
		CommonNames:      []string{"yolo", "yolov3", "yolov4", "yolov5", "yolov8", "ultralytics"},
		Keywords:         []string{"yolo", "detection", "detect", "ultralytics", "coco"},
		ImagePatterns:    []string{"yolo", "ultralytics"},
		CommandPatterns:  []string{"yolo", "detect.py", "train.py --data coco"},
		TypicalDataType:  types.DataTypeImage,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    7_000_000, // YOLOv5s
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "300Gi",
		RecommendedIOPS:         5000,
		RecommendedThroughput:   600,
		ReadWriteRatio:          0.85,
	}

	md.knowledgeBase[types.ModelViT] = &types.ModelProfile{
		ModelType:        types.ModelViT,
		ModelCategory:    types.ModelCategoryVision,
		CommonNames:      []string{"vit", "vision-transformer", "deit", "swin"},
		Keywords:         []string{"vit", "vision_transformer", "patch", "attention"},
		ImagePatterns:    []string{"vit", "deit", "swin"},
		CommandPatterns:  []string{"vit", "--model vit"},
		TypicalDataType:  types.DataTypeImage,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    86_000_000, // ViT-Base
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "300Gi",
		RecommendedIOPS:         6000,
		RecommendedThroughput:   600,
		ReadWriteRatio:          0.85,
	}

	md.knowledgeBase[types.ModelUNet] = &types.ModelProfile{
		ModelType:        types.ModelUNet,
		ModelCategory:    types.ModelCategoryVision,
		CommonNames:      []string{"unet", "u-net", "segmentation"},
		Keywords:         []string{"unet", "segmentation", "semantic", "mask"},
		ImagePatterns:    []string{"unet", "segmentation"},
		CommandPatterns:  []string{"unet", "segment", "--segmentation"},
		TypicalDataType:  types.DataTypeImage,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    31_000_000,
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "500Gi", // Large segmentation datasets
		RecommendedIOPS:         5000,
		RecommendedThroughput:   700,
		ReadWriteRatio:          0.8,
	}

	// =====================================================
	// NLP Models (자연어 처리)
	// =====================================================

	md.knowledgeBase[types.ModelBERT] = &types.ModelProfile{
		ModelType:        types.ModelBERT,
		ModelCategory:    types.ModelCategoryNLP,
		CommonNames:      []string{"bert", "bert-base", "bert-large", "roberta", "distilbert", "albert"},
		Keywords:         []string{"bert", "transformer", "tokenizer", "mlm", "nsp", "squad", "glue"},
		ImagePatterns:    []string{"bert", "transformers", "huggingface"},
		CommandPatterns:  []string{"bert", "--model bert", "run_glue", "run_squad"},
		TypicalDataType:  types.DataTypeText,
		TypicalIOPattern: types.IOPatternRandomRead,
		TypicalParams:    110_000_000, // BERT-base
		RecommendedStorageClass: "high-iops",
		RecommendedStorageSize:  "100Gi",
		RecommendedIOPS:         8000,
		RecommendedThroughput:   300,
		ReadWriteRatio:          0.9,
	}

	md.knowledgeBase[types.ModelGPT] = &types.ModelProfile{
		ModelType:        types.ModelGPT,
		ModelCategory:    types.ModelCategoryNLP,
		CommonNames:      []string{"gpt", "gpt2", "gpt-2", "gpt3", "gpt-3", "gpt4", "gpt-4"},
		Keywords:         []string{"gpt", "autoregressive", "causal", "generation", "lm"},
		ImagePatterns:    []string{"gpt", "openai"},
		CommandPatterns:  []string{"gpt", "--model gpt", "generate", "run_clm"},
		TypicalDataType:  types.DataTypeText,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    1_500_000_000, // GPT-2 Large
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "500Gi",
		RecommendedIOPS:         5000,
		RecommendedThroughput:   600,
		ReadWriteRatio:          0.85,
	}

	md.knowledgeBase[types.ModelLLaMA] = &types.ModelProfile{
		ModelType:        types.ModelLLaMA,
		ModelCategory:    types.ModelCategoryNLP,
		CommonNames:      []string{"llama", "llama2", "llama-2", "llama3", "codellama", "meta-llama"},
		Keywords:         []string{"llama", "meta", "codellama", "instruction", "chat"},
		ImagePatterns:    []string{"llama", "meta-llama"},
		CommandPatterns:  []string{"llama", "--model llama", "meta-llama"},
		TypicalDataType:  types.DataTypeText,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    7_000_000_000, // LLaMA-7B
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "1Ti",
		RecommendedIOPS:         10000,
		RecommendedThroughput:   800,
		ReadWriteRatio:          0.8,
	}

	md.knowledgeBase[types.ModelMistral] = &types.ModelProfile{
		ModelType:        types.ModelMistral,
		ModelCategory:    types.ModelCategoryNLP,
		CommonNames:      []string{"mistral", "mixtral", "mistral-7b"},
		Keywords:         []string{"mistral", "mixtral", "moe"},
		ImagePatterns:    []string{"mistral", "mixtral"},
		CommandPatterns:  []string{"mistral", "--model mistral"},
		TypicalDataType:  types.DataTypeText,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    7_000_000_000,
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "500Gi",
		RecommendedIOPS:         8000,
		RecommendedThroughput:   700,
		ReadWriteRatio:          0.85,
	}

	md.knowledgeBase[types.ModelT5] = &types.ModelProfile{
		ModelType:        types.ModelT5,
		ModelCategory:    types.ModelCategoryNLP,
		CommonNames:      []string{"t5", "t5-base", "t5-large", "flan-t5", "mt5"},
		Keywords:         []string{"t5", "seq2seq", "encoder-decoder", "flan"},
		ImagePatterns:    []string{"t5", "flan"},
		CommandPatterns:  []string{"t5", "--model t5", "run_seq2seq"},
		TypicalDataType:  types.DataTypeText,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    220_000_000, // T5-base
		RecommendedStorageClass: "balanced",
		RecommendedStorageSize:  "200Gi",
		RecommendedIOPS:         5000,
		RecommendedThroughput:   400,
		ReadWriteRatio:          0.85,
	}

	// =====================================================
	// Audio Models (오디오)
	// =====================================================

	md.knowledgeBase[types.ModelWhisper] = &types.ModelProfile{
		ModelType:        types.ModelWhisper,
		ModelCategory:    types.ModelCategoryAudio,
		CommonNames:      []string{"whisper", "openai-whisper", "whisper-large"},
		Keywords:         []string{"whisper", "asr", "speech", "transcribe", "audio"},
		ImagePatterns:    []string{"whisper", "openai-whisper"},
		CommandPatterns:  []string{"whisper", "--model whisper", "transcribe"},
		TypicalDataType:  types.DataTypeAudio,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    1_550_000_000, // Whisper-large
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "500Gi", // Large audio datasets
		RecommendedIOPS:         5000,
		RecommendedThroughput:   500,
		ReadWriteRatio:          0.9,
	}

	md.knowledgeBase[types.ModelWav2Vec] = &types.ModelProfile{
		ModelType:        types.ModelWav2Vec,
		ModelCategory:    types.ModelCategoryAudio,
		CommonNames:      []string{"wav2vec", "wav2vec2", "wav2vec-2"},
		Keywords:         []string{"wav2vec", "wav2vec2", "speech", "audio", "ssl"},
		ImagePatterns:    []string{"wav2vec"},
		CommandPatterns:  []string{"wav2vec", "--model wav2vec"},
		TypicalDataType:  types.DataTypeAudio,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    317_000_000, // wav2vec2-base
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "1Ti", // Very large audio datasets for SSL
		RecommendedIOPS:         5000,
		RecommendedThroughput:   600,
		ReadWriteRatio:          0.95,
	}

	// =====================================================
	// Multimodal Models (멀티모달)
	// =====================================================

	md.knowledgeBase[types.ModelCLIP] = &types.ModelProfile{
		ModelType:        types.ModelCLIP,
		ModelCategory:    types.ModelCategoryMultimodal,
		CommonNames:      []string{"clip", "openclip", "clip-vit"},
		Keywords:         []string{"clip", "contrastive", "image-text", "multimodal"},
		ImagePatterns:    []string{"clip", "openclip"},
		CommandPatterns:  []string{"clip", "--model clip"},
		TypicalDataType:  types.DataTypeImage, // Primary modality
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    400_000_000, // CLIP ViT-L/14
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "1Ti", // Large image-text datasets
		RecommendedIOPS:         8000,
		RecommendedThroughput:   700,
		ReadWriteRatio:          0.9,
	}

	md.knowledgeBase[types.ModelStableDiffusion] = &types.ModelProfile{
		ModelType:        types.ModelStableDiffusion,
		ModelCategory:    types.ModelCategoryMultimodal,
		CommonNames:      []string{"stable-diffusion", "stablediffusion", "sd", "sdxl"},
		Keywords:         []string{"diffusion", "stable-diffusion", "sd", "sdxl", "generation", "image"},
		ImagePatterns:    []string{"stable-diffusion", "sd-", "diffusers"},
		CommandPatterns:  []string{"diffusion", "--model sd", "txt2img", "img2img"},
		TypicalDataType:  types.DataTypeImage,
		TypicalIOPattern: types.IOPatternBalanced, // Read prompts, write images
		TypicalParams:    860_000_000, // SD 1.5
		RecommendedStorageClass: "balanced",
		RecommendedStorageSize:  "200Gi",
		RecommendedIOPS:         5000,
		RecommendedThroughput:   400,
		ReadWriteRatio:          0.5, // Balanced read/write
	}

	md.knowledgeBase[types.ModelLLaVA] = &types.ModelProfile{
		ModelType:        types.ModelLLaVA,
		ModelCategory:    types.ModelCategoryMultimodal,
		CommonNames:      []string{"llava", "llava-1.5", "llava-v1.6"},
		Keywords:         []string{"llava", "vision-language", "vqa", "multimodal"},
		ImagePatterns:    []string{"llava"},
		CommandPatterns:  []string{"llava", "--model llava"},
		TypicalDataType:  types.DataTypeImage,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    7_000_000_000,
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "500Gi",
		RecommendedIOPS:         8000,
		RecommendedThroughput:   600,
		ReadWriteRatio:          0.85,
	}

	// =====================================================
	// Generative Models (생성 모델)
	// =====================================================

	md.knowledgeBase[types.ModelGAN] = &types.ModelProfile{
		ModelType:        types.ModelGAN,
		ModelCategory:    types.ModelCategoryGenerative,
		CommonNames:      []string{"gan", "dcgan", "stylegan", "cyclegan", "pix2pix"},
		Keywords:         []string{"gan", "generator", "discriminator", "adversarial"},
		ImagePatterns:    []string{"gan", "stylegan"},
		CommandPatterns:  []string{"gan", "train_gan", "--generator"},
		TypicalDataType:  types.DataTypeImage,
		TypicalIOPattern: types.IOPatternSequentialRead,
		TypicalParams:    30_000_000, // StyleGAN2
		RecommendedStorageClass: "high-throughput",
		RecommendedStorageSize:  "500Gi",
		RecommendedIOPS:         5000,
		RecommendedThroughput:   500,
		ReadWriteRatio:          0.7,
	}

	md.knowledgeBase[types.ModelDiffusion] = &types.ModelProfile{
		ModelType:        types.ModelDiffusion,
		ModelCategory:    types.ModelCategoryGenerative,
		CommonNames:      []string{"diffusion", "ddpm", "ddim", "score"},
		Keywords:         []string{"diffusion", "ddpm", "denoise", "score"},
		ImagePatterns:    []string{"diffusion", "ddpm"},
		CommandPatterns:  []string{"diffusion", "--diffusion"},
		TypicalDataType:  types.DataTypeImage,
		TypicalIOPattern: types.IOPatternBalanced,
		TypicalParams:    500_000_000,
		RecommendedStorageClass: "balanced",
		RecommendedStorageSize:  "300Gi",
		RecommendedIOPS:         5000,
		RecommendedThroughput:   400,
		ReadWriteRatio:          0.6,
	}
}

// DetectFromYAML detects AI model from YAML analysis results
func (md *ModelDetector) DetectFromYAML(yamlResult *types.YAMLAnalysisResult) *types.AIModelSignature {
	signature := &types.AIModelSignature{
		ModelCategory:   types.ModelCategoryUnknown,
		ModelType:       types.ModelUnknown,
		Framework:       types.FrameworkUnknown,
		DataType:        types.DataTypeUnknown,
		IOPattern:       types.IOPatternBalanced,
		DetectionSource: "yaml",
		DetectedAt:      time.Now(),
		Confidence:      0.0,
	}

	if yamlResult == nil {
		return signature
	}

	// Use inferred values from YAML analysis
	signature.ModelType = yamlResult.InferredModel
	signature.ModelCategory = yamlResult.InferredCategory
	signature.Framework = yamlResult.InferredFramework
	signature.DataType = yamlResult.InferredDataType
	signature.Confidence = yamlResult.Confidence

	// Get recommendations from knowledge base
	if profile, ok := md.knowledgeBase[signature.ModelType]; ok {
		signature.IOPattern = profile.TypicalIOPattern
		signature.ReadWriteRatio = profile.ReadWriteRatio
		signature.EstimatedParams = profile.TypicalParams
		signature.RecommendedStorageClass = profile.RecommendedStorageClass
		signature.RecommendedStorageSize = profile.RecommendedStorageSize
		signature.RecommendedIOPS = profile.RecommendedIOPS
		signature.RecommendedThroughput = profile.RecommendedThroughput

		// Boost confidence if we have a known profile
		signature.Confidence = minFloat(signature.Confidence+0.1, 1.0)
	} else {
		// Default recommendations based on category
		md.applyDefaultRecommendations(signature)
	}

	// Extract additional info from YAML
	if yamlResult.CommandAnalysis != nil {
		if yamlResult.CommandAnalysis.BatchSize > 0 {
			signature.BatchSize = yamlResult.CommandAnalysis.BatchSize
		}
	}

	return signature
}

// DetectFromTrace detects AI model from Insight Trace data
func (md *ModelDetector) DetectFromTrace(traceResult *types.TraceAnalysisResult) *types.AIModelSignature {
	signature := &types.AIModelSignature{
		ModelCategory:   types.ModelCategoryUnknown,
		ModelType:       types.ModelUnknown,
		Framework:       types.FrameworkUnknown,
		DataType:        types.DataTypeUnknown,
		IOPattern:       types.IOPatternBalanced,
		DetectionSource: "trace",
		DetectedAt:      time.Now(),
		Confidence:      0.0,
	}

	if traceResult == nil || !traceResult.TraceAvailable {
		return signature
	}

	// Use detected values from trace
	signature.ModelType = traceResult.DetectedModel
	signature.ModelCategory = traceResult.DetectedCategory
	signature.Framework = traceResult.DetectedFramework
	signature.IOPattern = traceResult.DetectedIOPattern
	signature.Confidence = traceResult.Confidence

	// Infer data type from category
	signature.DataType = md.inferDataTypeFromCategory(signature.ModelCategory)

	// Refine detection based on resource usage patterns
	signature = md.refineFromResourcePatterns(signature, traceResult)

	// Get recommendations from knowledge base
	if profile, ok := md.knowledgeBase[signature.ModelType]; ok {
		signature.ReadWriteRatio = profile.ReadWriteRatio
		signature.EstimatedParams = profile.TypicalParams
		signature.RecommendedStorageClass = profile.RecommendedStorageClass
		signature.RecommendedStorageSize = profile.RecommendedStorageSize
		signature.RecommendedIOPS = profile.RecommendedIOPS
		signature.RecommendedThroughput = profile.RecommendedThroughput
	} else {
		md.applyDefaultRecommendations(signature)
	}

	return signature
}

// CombineDetections combines YAML and Trace detections for best accuracy
func (md *ModelDetector) CombineDetections(yamlSig, traceSig *types.AIModelSignature) *types.AIModelSignature {
	combined := &types.AIModelSignature{
		DetectionSource: "combined",
		DetectedAt:      time.Now(),
	}

	// Prioritize trace data if available with good confidence
	if traceSig != nil && traceSig.Confidence >= 0.7 {
		*combined = *traceSig
		combined.DetectionSource = "combined"

		// Supplement with YAML data
		if yamlSig != nil {
			if combined.ModelType == types.ModelUnknown && yamlSig.ModelType != types.ModelUnknown {
				combined.ModelType = yamlSig.ModelType
			}
			if combined.Framework == types.FrameworkUnknown && yamlSig.Framework != types.FrameworkUnknown {
				combined.Framework = yamlSig.Framework
			}
			if yamlSig.BatchSize > 0 {
				combined.BatchSize = yamlSig.BatchSize
			}

			// Combine confidence
			combined.Confidence = (traceSig.Confidence*0.6 + yamlSig.Confidence*0.4)
		}
	} else if yamlSig != nil {
		*combined = *yamlSig
		combined.DetectionSource = "combined"

		// Supplement with trace data
		if traceSig != nil && traceSig.Confidence > 0 {
			if traceSig.IOPattern != types.IOPatternBalanced {
				combined.IOPattern = traceSig.IOPattern
			}
			// Combine confidence
			combined.Confidence = (yamlSig.Confidence*0.5 + traceSig.Confidence*0.5)
		}
	}

	// Ensure we have recommendations
	if combined.RecommendedStorageClass == "" {
		if profile, ok := md.knowledgeBase[combined.ModelType]; ok {
			combined.RecommendedStorageClass = profile.RecommendedStorageClass
			combined.RecommendedStorageSize = profile.RecommendedStorageSize
			combined.RecommendedIOPS = profile.RecommendedIOPS
			combined.RecommendedThroughput = profile.RecommendedThroughput
		} else {
			md.applyDefaultRecommendations(combined)
		}
	}

	return combined
}

// refineFromResourcePatterns refines model detection based on resource usage
func (md *ModelDetector) refineFromResourcePatterns(sig *types.AIModelSignature, trace *types.TraceAnalysisResult) *types.AIModelSignature {
	// High GPU usage + sequential read = likely training
	if trace.AvgGPUUsage > 70 && trace.DetectedIOPattern == types.IOPatternSequentialRead {
		// This is typical for vision models training
		if sig.ModelCategory == types.ModelCategoryUnknown {
			sig.ModelCategory = types.ModelCategoryVision
			sig.DataType = types.DataTypeImage
			sig.Confidence += 0.1
		}
	}

	// High CPU + moderate GPU + random read = likely NLP
	if trace.AvgCPUUsage > 50 && trace.AvgGPUUsage > 0 && trace.AvgGPUUsage < 70 {
		if trace.DetectedIOPattern == types.IOPatternRandomRead {
			if sig.ModelCategory == types.ModelCategoryUnknown {
				sig.ModelCategory = types.ModelCategoryNLP
				sig.DataType = types.DataTypeText
				sig.Confidence += 0.1
			}
		}
	}

	// Very high read throughput + high GPU = LLM training
	if trace.AvgReadThroughput > 500 && trace.AvgGPUUsage > 80 {
		if sig.ModelType == types.ModelUnknown {
			sig.ModelCategory = types.ModelCategoryNLP
			sig.Confidence += 0.1
		}
	}

	return sig
}

// inferDataTypeFromCategory infers data type from model category
func (md *ModelDetector) inferDataTypeFromCategory(category types.AIModelCategory) types.DataType {
	switch category {
	case types.ModelCategoryVision:
		return types.DataTypeImage
	case types.ModelCategoryNLP:
		return types.DataTypeText
	case types.ModelCategoryAudio:
		return types.DataTypeAudio
	case types.ModelCategoryMultimodal:
		return types.DataTypeImage
	default:
		return types.DataTypeUnknown
	}
}

// applyDefaultRecommendations applies default storage recommendations
func (md *ModelDetector) applyDefaultRecommendations(sig *types.AIModelSignature) {
	switch sig.ModelCategory {
	case types.ModelCategoryVision:
		sig.RecommendedStorageClass = "high-throughput"
		sig.RecommendedStorageSize = "500Gi"
		sig.RecommendedIOPS = 5000
		sig.RecommendedThroughput = 500
		sig.ReadWriteRatio = 0.85
	case types.ModelCategoryNLP:
		sig.RecommendedStorageClass = "high-iops"
		sig.RecommendedStorageSize = "200Gi"
		sig.RecommendedIOPS = 8000
		sig.RecommendedThroughput = 300
		sig.ReadWriteRatio = 0.9
	case types.ModelCategoryAudio:
		sig.RecommendedStorageClass = "high-throughput"
		sig.RecommendedStorageSize = "500Gi"
		sig.RecommendedIOPS = 5000
		sig.RecommendedThroughput = 500
		sig.ReadWriteRatio = 0.9
	case types.ModelCategoryMultimodal:
		sig.RecommendedStorageClass = "high-throughput"
		sig.RecommendedStorageSize = "1Ti"
		sig.RecommendedIOPS = 8000
		sig.RecommendedThroughput = 700
		sig.ReadWriteRatio = 0.8
	case types.ModelCategoryGenerative:
		sig.RecommendedStorageClass = "balanced"
		sig.RecommendedStorageSize = "300Gi"
		sig.RecommendedIOPS = 5000
		sig.RecommendedThroughput = 400
		sig.ReadWriteRatio = 0.6
	default:
		sig.RecommendedStorageClass = "standard"
		sig.RecommendedStorageSize = "200Gi"
		sig.RecommendedIOPS = 3000
		sig.RecommendedThroughput = 200
		sig.ReadWriteRatio = 0.7
	}
}

// GetModelProfile returns the profile for a known model
func (md *ModelDetector) GetModelProfile(modelType types.AIModelType) *types.ModelProfile {
	if profile, ok := md.knowledgeBase[modelType]; ok {
		return profile
	}
	return nil
}

// SearchModelByKeyword searches for models matching a keyword
func (md *ModelDetector) SearchModelByKeyword(keyword string) []types.AIModelType {
	keyword = strings.ToLower(keyword)
	var matches []types.AIModelType

	for modelType, profile := range md.knowledgeBase {
		// Check common names
		for _, name := range profile.CommonNames {
			if strings.Contains(strings.ToLower(name), keyword) {
				matches = append(matches, modelType)
				break
			}
		}
		// Check keywords
		for _, kw := range profile.Keywords {
			if strings.Contains(strings.ToLower(kw), keyword) {
				// Avoid duplicates
				found := false
				for _, m := range matches {
					if m == modelType {
						found = true
						break
					}
				}
				if !found {
					matches = append(matches, modelType)
				}
				break
			}
		}
	}

	return matches
}

// ListAllModels returns all known model types
func (md *ModelDetector) ListAllModels() []types.AIModelType {
	models := make([]types.AIModelType, 0, len(md.knowledgeBase))
	for model := range md.knowledgeBase {
		models = append(models, model)
	}
	return models
}

// helper functions
func minFloat(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}
