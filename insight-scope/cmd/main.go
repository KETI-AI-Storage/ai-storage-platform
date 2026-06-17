package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	"insight-scope/pkg/apis"
	"insight-scope/pkg/collector"
	"insight-scope/pkg/controller"
	scopeGrpc "insight-scope/pkg/grpc"
)

func main() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lshortfile)
	log.Println("==============================================")
	log.Println("  Insight Scope - AI Workload Analysis")
	log.Println("  KETI APOLLO System Component")
	log.Println("==============================================")

	// Get configuration
	port := os.Getenv("HTTP_PORT")
	if port == "" {
		port = os.Getenv("PORT")
		if port == "" {
			port = "9092"
		}
	}
	grpcPort := os.Getenv("GRPC_PORT")
	if grpcPort == "" {
		grpcPort = "50054"
	}
	kubeconfig := os.Getenv("KUBECONFIG")

	// Initialize scope controller
	scopeController, err := controller.NewScopeController(kubeconfig)
	if err != nil {
		log.Fatalf("Failed to create scope controller: %v", err)
	}
	log.Println("Scope controller initialized")

	// Initialize gRPC server
	grpcServer := scopeGrpc.NewScopeServer(scopeController, grpcPort)
	if err := grpcServer.Start(); err != nil {
		log.Fatalf("Failed to start gRPC server: %v", err)
	}
	log.Printf("gRPC server started on port %s", grpcPort)

	// Initialize metrics collector (sends data to Node Resource Forecaster)
	var metricsCollector *collector.MetricsCollector
	enableForecaster := os.Getenv("ENABLE_FORECASTER")
	if enableForecaster == "true" || enableForecaster == "1" {
		metricsCollector, err = collector.NewMetricsCollector(kubeconfig)
		if err != nil {
			log.Printf("Warning: Failed to create metrics collector: %v", err)
		} else {
			metricsCollector.Start()
			if hub := os.Getenv("INSIGHT_HUB_ENDPOINT"); hub != "" {
				log.Printf("[scope-metrics] collector started — node resource snapshots → Insight Hub %s (key=NODE_NAME, not pod name; flush ~every 5m or 60 snaps)", hub)
			} else {
				log.Println("[scope-metrics] collector started — snapshots → FORECASTER_ENDPOINT (SubmitHistoryData), no INSIGHT_HUB_ENDPOINT")
			}
		}
	}

	// Initialize API handler
	handler := apis.NewHandler(scopeController)
	router := handler.SetupRoutes()

	// Log available endpoints
	log.Printf("HTTP server starting on port %s", port)
	log.Println("Available endpoints:")
	log.Println("  POST   /api/v1/scope/analyze - Analyze a pod (YAML or existing)")
	log.Println("  GET    /api/v1/scope/pod/:namespace/:name - Get pod analysis")
	log.Println("  GET    /api/v1/scope/pods/:namespace - List pod analyses in namespace")
	log.Println("  GET    /api/v1/scope/cache - List cached analyses")
	log.Println("  GET    /api/v1/models - List all known AI models")
	log.Println("  GET    /api/v1/models/:model - Get model profile")
	log.Println("  GET    /api/v1/models/search?q=keyword - Search models")
	log.Println("  POST   /api/v1/recommend - Get storage recommendation")
	log.Println("  GET    /api/v1/recommend/model/:model - Get recommendation by model")
	log.Println("  GET    /api/v1/recommend/category/:category - Get recommendation by category")
	log.Println("  GET    /health - Health check")
	log.Println("")
	log.Printf("gRPC server running on port %s", grpcPort)
	log.Println("gRPC services:")
	log.Println("  AnalyzePod - Analyze pod YAML or existing pod")
	log.Println("  GetCachedAnalysis - Get cached analysis result")
	log.Println("  AnalyzeNamespace - Analyze all pods in namespace")
	log.Println("  GetModelProfile - Get AI model profile")
	log.Println("  SearchModels - Search models by keyword")
	log.Println("  ListAllModels - List all known AI models")
	log.Println("  GetStorageRecommendation - Get storage recommendation")
	log.Println("  HealthCheck - gRPC health check")

	// Setup graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	// Start HTTP server in goroutine
	go func() {
		if err := router.Run(":" + port); err != nil {
			log.Fatalf("Failed to start HTTP server: %v", err)
		}
	}()

	log.Println("Insight Scope is ready")

	// Wait for interrupt signal
	<-quit
	log.Println("Shutting down Insight Scope...")
	if metricsCollector != nil {
		metricsCollector.Stop()
	}
	grpcServer.Stop()
	log.Println("Graceful shutdown completed")
}
