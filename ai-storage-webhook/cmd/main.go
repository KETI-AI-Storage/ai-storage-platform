// =============================================================================
// AI Storage Mutating Admission Webhook - Entry Point
//
// 역할:
//   HTTPS 서버를 시작하여 Kubernetes API Server의 AdmissionReview 요청을 수신.
//   Pod 생성 시 3가지 자동 주입:
//     1. schedulerName → ai-storage-scheduler
//     2. shareProcessNamespace → true
//     3. Insight-Trace 사이드카 컨테이너 추가
//
// 동작 흐름:
//   사용자가 Pod 생성 요청
//     → K8s API Server가 이 웹훅 서버에 AdmissionReview 전송
//     → 웹훅이 JSON Patch 응답 반환
//     → API Server가 패치 적용 후 Pod 생성
//
// TLS 필수:
//   K8s API Server는 웹훅을 HTTPS로만 호출함.
//   /certs/tls.crt, /certs/tls.key 경로에 인증서 필요.
// =============================================================================
package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"keti/ai-storage-webhook/pkg/webhook"
)

func main() {
	// 로그 앞의 기본 날짜/시간 프리픽스를 제거한다.
	log.SetFlags(0)

	// =========================================================================
	// 커맨드라인 플래그 정의
	//
	// --port: 웹훅 서버 포트 (기본: 8443)
	// --cert-dir: TLS 인증서 디렉토리 (기본: /certs)
	// --sidecar-image: 주입할 Insight-Trace 이미지
	// --apollo-endpoint: APOLLO gRPC 서버 주소
	// =========================================================================
	port := flag.Int("port", 8443, "Webhook server port")
	certDir := flag.String("cert-dir", "/certs", "TLS certificate directory")
	sidecarImage := flag.String("sidecar-image", "ketidevit2/insight-trace:latest", "Insight-Trace sidecar image")
	apolloEndpoint := flag.String("apollo-endpoint", "apollo-policy-server.keti.svc.cluster.local:50051", "APOLLO gRPC endpoint")
	schedulerName := flag.String("scheduler-name", "ai-storage-scheduler", "Custom scheduler name to inject")
	flag.Parse()

	// =========================================================================
	// 환경변수 오버라이드
	//
	// 컨테이너 배포 시 환경변수로 설정을 변경할 수 있음.
	// 플래그보다 환경변수가 우선.
	// =========================================================================
	if v := os.Getenv("SIDECAR_IMAGE"); v != "" {
		*sidecarImage = v
	}
	if v := os.Getenv("APOLLO_ENDPOINT"); v != "" {
		*apolloEndpoint = v
	}
	if v := os.Getenv("SCHEDULER_NAME"); v != "" {
		*schedulerName = v
	}
	planAPIBaseURL := os.Getenv("PLAN_API_BASE_URL")
	if planAPIBaseURL == "" {
		planAPIBaseURL = "http://ai-storage-orchestrator.kube-system.svc.cluster.local:8080"
	}

	// =========================================================================
	// 웹훅 핸들러 생성
	//
	// WebhookConfig: 주입할 설정값들을 담은 구조체
	// NewMutationHandler: AdmissionReview를 처리하는 HTTP 핸들러 생성
	// =========================================================================
	config := webhook.WebhookConfig{
		SidecarImage:              *sidecarImage,
		ApolloEndpoint:            *apolloEndpoint,
		SchedulerName:             *schedulerName,
		PlanAPIBaseURL:            planAPIBaseURL,
		ReplaceableStorageClasses: webhook.ReplaceableStorageClassesFromEnv(),
	}
	handler := webhook.NewMutationHandler(config)

	// =========================================================================
	// HTTP 라우팅 설정
	//
	// /mutate  : MutatingWebhookConfiguration에서 지정한 경로.
	//            K8s API Server가 Pod 생성 시 이 경로로 POST 요청.
	// /healthz : 헬스체크 (Deployment의 livenessProbe/readinessProbe용)
	// =========================================================================
	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", handler.Handle)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// =========================================================================
	// TLS 설정
	//
	// K8s API Server → 웹훅 통신은 반드시 HTTPS.
	// tls.crt / tls.key는 scripts/generate-certs.sh로 생성하거나
	// cert-manager가 자동 생성.
	// =========================================================================
	certFile := fmt.Sprintf("%s/tls.crt", *certDir)
	keyFile := fmt.Sprintf("%s/tls.key", *certDir)

	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatalf("[Webhook] Failed to load TLS certificates: %v", err)
	}

	server := &http.Server{
		Addr:    fmt.Sprintf(":%d", *port),
		Handler: mux,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{cert},
		},
	}

	// =========================================================================
	// Graceful Shutdown
	//
	// SIGTERM/SIGINT 수신 시 서버를 정상 종료.
	// K8s가 Pod 삭제 시 SIGTERM을 보내므로 이를 처리.
	// =========================================================================
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		log.Printf("[Webhook] Starting HTTPS server on :%d", *port)
		log.Printf("[Webhook] Config: scheduler=%s, sidecar=%s", *schedulerName, *sidecarImage)
		log.Printf("[Webhook] APOLLO endpoint: %s", *apolloEndpoint)
		if err := server.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[Webhook] Server failed: %v", err)
		}
	}()

	<-stop
	log.Println("[Webhook] Shutting down...")
	server.Close()
}
