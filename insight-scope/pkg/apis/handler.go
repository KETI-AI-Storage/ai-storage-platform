package apis

import (
	"net/http"

	"insight-scope/pkg/controller"
	"insight-scope/pkg/types"

	"github.com/gin-gonic/gin"
)

// Handler handles HTTP API requests
type Handler struct {
	scopeController *controller.ScopeController
}

// NewHandler creates a new API handler
func NewHandler(scopeController *controller.ScopeController) *Handler {
	return &Handler{
		scopeController: scopeController,
	}
}

// SetupRoutes sets up the HTTP routes
func (h *Handler) SetupRoutes() *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Recovery())
	router.Use(gin.Logger())

	// Health check
	router.GET("/health", h.handleHealth)
	router.GET("/ready", h.handleReady)

	// API v1 routes
	v1 := router.Group("/api/v1")
	{
		// Scope analysis endpoints
		scope := v1.Group("/scope")
		{
			scope.POST("/analyze", h.handleAnalyze)
			scope.GET("/pod/:namespace/:name", h.handleGetPodAnalysis)
			scope.GET("/pods/:namespace", h.handleListPodAnalyses)
			scope.GET("/cache", h.handleListCache)
		}

		// Model knowledge base endpoints
		models := v1.Group("/models")
		{
			models.GET("", h.handleListModels)
			models.GET("/:model", h.handleGetModelProfile)
			models.GET("/search", h.handleSearchModels)
		}

		// Recommendation endpoints
		recommend := v1.Group("/recommend")
		{
			recommend.POST("", h.handleRecommend)
			recommend.GET("/model/:model", h.handleRecommendByModel)
			recommend.GET("/category/:category", h.handleRecommendByCategory)
		}
	}

	return router
}

// handleHealth handles health check
func (h *Handler) handleHealth(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status":    "healthy",
		"component": "insight-scope",
	})
}

// handleReady handles readiness check
func (h *Handler) handleReady(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status": "ready",
	})
}

// handleAnalyze handles scope analysis request
func (h *Handler) handleAnalyze(c *gin.Context) {
	var req types.ScopeAnalysisRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	result, err := h.scopeController.AnalyzePod(c.Request.Context(), &req)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, result)
}

// handleGetPodAnalysis handles getting analysis for a specific pod
func (h *Handler) handleGetPodAnalysis(c *gin.Context) {
	namespace := c.Param("namespace")
	name := c.Param("name")

	// Check cache first
	cached := h.scopeController.GetCachedAnalysis(namespace, name)
	if cached != nil {
		c.JSON(http.StatusOK, cached)
		return
	}

	// Analyze if not cached
	req := &types.ScopeAnalysisRequest{
		PodName:          name,
		Namespace:        namespace,
		IncludeTraceData: c.Query("trace") == "true",
		WaitForTrace:     c.Query("wait") == "true",
	}

	result, err := h.scopeController.AnalyzePod(c.Request.Context(), req)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, result)
}

// handleListPodAnalyses handles listing all analyzed pods in a namespace
func (h *Handler) handleListPodAnalyses(c *gin.Context) {
	namespace := c.Param("namespace")

	results, err := h.scopeController.AnalyzeAllPods(c.Request.Context(), namespace)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"namespace": namespace,
		"count":     len(results),
		"analyses":  results,
	})
}

// handleListCache handles listing cached analyses
func (h *Handler) handleListCache(c *gin.Context) {
	results := h.scopeController.ListCachedAnalyses()

	c.JSON(http.StatusOK, gin.H{
		"count":    len(results),
		"analyses": results,
	})
}

// handleListModels handles listing all known models
func (h *Handler) handleListModels(c *gin.Context) {
	models := h.scopeController.ListAllModels()

	// Group by category
	categorized := make(map[string][]types.AIModelType)
	for _, model := range models {
		profile := h.scopeController.GetModelProfile(model)
		if profile != nil {
			category := string(profile.ModelCategory)
			categorized[category] = append(categorized[category], model)
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"total_count": len(models),
		"by_category": categorized,
		"all_models":  models,
	})
}

// handleGetModelProfile handles getting a model profile
func (h *Handler) handleGetModelProfile(c *gin.Context) {
	modelStr := c.Param("model")
	model := types.AIModelType(modelStr)

	profile := h.scopeController.GetModelProfile(model)
	if profile == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "model not found"})
		return
	}

	c.JSON(http.StatusOK, profile)
}

// handleSearchModels handles searching for models
func (h *Handler) handleSearchModels(c *gin.Context) {
	keyword := c.Query("q")
	if keyword == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "query parameter 'q' is required"})
		return
	}

	models := h.scopeController.SearchModels(keyword)

	results := make([]gin.H, 0, len(models))
	for _, model := range models {
		profile := h.scopeController.GetModelProfile(model)
		if profile != nil {
			results = append(results, gin.H{
				"model":    model,
				"category": profile.ModelCategory,
				"profile":  profile,
			})
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"query":   keyword,
		"count":   len(results),
		"results": results,
	})
}

// RecommendRequest represents a recommendation request
type RecommendRequest struct {
	ModelType     string `json:"model_type,omitempty"`
	ModelCategory string `json:"model_category,omitempty"`
	WorkloadType  string `json:"workload_type,omitempty"`
	Stage         string `json:"stage,omitempty"`
	GPUCount      int    `json:"gpu_count,omitempty"`
	DataSizeGB    int    `json:"data_size_gb,omitempty"`
}

// handleRecommend handles storage recommendation request
func (h *Handler) handleRecommend(c *gin.Context) {
	var req RecommendRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	recommendation := h.generateRecommendation(&req)
	c.JSON(http.StatusOK, recommendation)
}

// handleRecommendByModel handles recommendation by model type
func (h *Handler) handleRecommendByModel(c *gin.Context) {
	modelStr := c.Param("model")
	model := types.AIModelType(modelStr)

	profile := h.scopeController.GetModelProfile(model)
	if profile == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "model not found"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"model":   model,
		"profile": profile,
		"recommendation": types.StorageRecommendation{
			StorageClass:   profile.RecommendedStorageClass,
			StorageSize:    profile.RecommendedStorageSize,
			IOPS:           profile.RecommendedIOPS,
			ThroughputMBps: profile.RecommendedThroughput,
			AccessMode:     "ReadWriteOnce",
			Reasoning:      "Based on " + string(model) + " model profile",
		},
	})
}

// handleRecommendByCategory handles recommendation by category
func (h *Handler) handleRecommendByCategory(c *gin.Context) {
	categoryStr := c.Param("category")
	category := types.AIModelCategory(categoryStr)

	recommendation := h.getRecommendationByCategory(category)
	c.JSON(http.StatusOK, gin.H{
		"category":       category,
		"recommendation": recommendation,
	})
}

// generateRecommendation generates storage recommendation
func (h *Handler) generateRecommendation(req *RecommendRequest) *types.StorageRecommendation {
	rec := &types.StorageRecommendation{
		AccessMode: "ReadWriteOnce",
	}

	// If model type specified, use its profile
	if req.ModelType != "" {
		model := types.AIModelType(req.ModelType)
		profile := h.scopeController.GetModelProfile(model)
		if profile != nil {
			rec.StorageClass = profile.RecommendedStorageClass
			rec.StorageSize = profile.RecommendedStorageSize
			rec.IOPS = profile.RecommendedIOPS
			rec.ThroughputMBps = profile.RecommendedThroughput
			rec.Reasoning = "Based on " + req.ModelType + " model profile"
			return rec
		}
	}

	// If category specified, use category defaults
	if req.ModelCategory != "" {
		category := types.AIModelCategory(req.ModelCategory)
		return h.getRecommendationByCategory(category)
	}

	// Default recommendation
	rec.StorageClass = "balanced"
	rec.StorageSize = "200Gi"
	rec.IOPS = 5000
	rec.ThroughputMBps = 300
	rec.Reasoning = "Default balanced recommendation"

	// Adjust based on GPU count
	if req.GPUCount > 0 {
		rec.ThroughputMBps += int64(req.GPUCount * 100)
		rec.IOPS += int64(req.GPUCount * 1000)
		rec.Reasoning += " (adjusted for " + string(rune(req.GPUCount+'0')) + " GPUs)"
	}

	// Adjust based on data size
	if req.DataSizeGB > 0 {
		rec.StorageSize = h.calculateStorageSize(req.DataSizeGB)
	}

	return rec
}

// getRecommendationByCategory gets recommendation by category
func (h *Handler) getRecommendationByCategory(category types.AIModelCategory) *types.StorageRecommendation {
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
		rec.Reasoning = "Vision workloads benefit from high sequential read throughput for large image datasets"

	case types.ModelCategoryNLP:
		rec.StorageClass = "high-iops"
		rec.StorageSize = "200Gi"
		rec.IOPS = 8000
		rec.ThroughputMBps = 300
		rec.CacheTier = "ssd"
		rec.Reasoning = "NLP workloads benefit from high IOPS for tokenized data access"

	case types.ModelCategoryAudio:
		rec.StorageClass = "high-throughput"
		rec.StorageSize = "500Gi"
		rec.IOPS = 5000
		rec.ThroughputMBps = 500
		rec.CacheTier = "nvme"
		rec.Reasoning = "Audio workloads require high throughput for streaming audio data"

	case types.ModelCategoryMultimodal:
		rec.StorageClass = "high-throughput"
		rec.StorageSize = "1Ti"
		rec.IOPS = 8000
		rec.ThroughputMBps = 700
		rec.CacheTier = "nvme"
		rec.Reasoning = "Multimodal workloads need high throughput for multiple data modalities"

	case types.ModelCategoryGenerative:
		rec.StorageClass = "balanced"
		rec.StorageSize = "300Gi"
		rec.IOPS = 5000
		rec.ThroughputMBps = 400
		rec.CacheTier = "ssd"
		rec.Reasoning = "Generative workloads have balanced I/O patterns"

	default:
		rec.StorageClass = "standard"
		rec.StorageSize = "200Gi"
		rec.IOPS = 3000
		rec.ThroughputMBps = 200
		rec.CacheTier = "ssd"
		rec.Reasoning = "Standard recommendation for unknown category"
	}

	return rec
}

// calculateStorageSize calculates storage size based on data size
func (h *Handler) calculateStorageSize(dataSizeGB int) string {
	// Add 50% overhead for checkpoints, logs, etc.
	totalSize := int(float64(dataSizeGB) * 1.5)

	if totalSize >= 1024 {
		return string(rune(totalSize/1024+'0')) + "Ti"
	}
	return string(rune(totalSize+'0')) + "Gi"
}
