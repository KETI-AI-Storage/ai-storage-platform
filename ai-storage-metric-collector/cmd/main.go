package main

import (
	"context"
	"keti/ai-storage-metric-collector/pkg/collect"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

// version identifies the build; bumped to exercise the CI/CD pipeline.
const version = "0.1.0"

func main() {
	log.Printf("ai-storage-metric-collector starting (version %s)", version)

	quitChan := make(chan struct{})
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())

	metricCollector := collect.NewMetricCollector()

	wg.Add(1)
	go metricCollector.RunMetricCollector(ctx, &wg) // goroutine으로 실행

	signalChan := make(chan os.Signal, 1)
	signal.Notify(signalChan, syscall.SIGINT, syscall.SIGTERM)

	<-signalChan
	close(quitChan)
	cancel()
	wg.Wait()
	os.Exit(0)
}
