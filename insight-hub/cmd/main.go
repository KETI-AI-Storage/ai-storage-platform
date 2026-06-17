package main

import (
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	grpcsvc "insight-hub/internal/grpc"
	"insight-hub/internal/store"
	"insight-hub/internal/volumes"
)

func main() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lshortfile)
	layout := volumes.FromEnv()
	if err := layout.EnsureWorkDirs(); err != nil {
		log.Fatalf("volumes: %v", err)
	}
	dbPath := os.Getenv("SQLITE_PATH")
	if dbPath == "" {
		dbPath = store.DefaultPath()
	}
	st, err := store.Open(dbPath)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	defer st.Close()
	addr := grpcsvc.ListenAddr()
	log.Printf("[hub.startup] sqlite_path=%s grpc_listen=%s (ingest=SubmitHistoryData → SQLite)", dbPath, addr)
	log.Printf("[hub.volumes] data=%s checkpoint=%s cache=%s output=%s", layout.Data, layout.Checkpoint, layout.Cache, layout.Output)

	stop := make(chan struct{})
	grpcsvc.StartPruneLoop(st, stop)

	srv, err := grpcsvc.Serve(addr, st)
	if err != nil {
		log.Fatalf("grpc: %v", err)
	}

	httpPort := os.Getenv("HTTP_PORT")
	if httpPort == "" {
		httpPort = "8081"
	}
	httpAddr := ":" + httpPort
	httpSrv := &http.Server{
		Addr:    httpAddr,
		Handler: grpcsvc.OrchestrationResultIngestHandler(st),
	}
	go func() {
		log.Printf("[hub] HTTP listening on %s (ingest=/api/v1/orchestration-results)", httpAddr)
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("[hub] HTTP serve: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	close(stop)
	_ = httpSrv.Close()
	srv.GracefulStop()
	log.Println("insight-hub stopped")
}
