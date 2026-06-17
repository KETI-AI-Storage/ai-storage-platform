package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

type GluesysRequest struct {
	WorkloadName string `json:"workload_name"`
	DatasetID    string `json:"dataset_id"`
	LogicalPath  string `json:"logical_path"`
	DataLocality string `json:"data_locality"`
	NodeName     string `json:"node_name"`
	PVCName      string `json:"pvc_name"`
	MountPath    string `json:"mount_path"`
}

type GluesysResponse struct {
	Status       string `json:"status"`
	StorageClass string `json:"storage_class"`
	DataPath     string `json:"data_path"`
	Message      string `json:"message"`
}

func main() {
	log.SetFlags(0)

	addr := os.Getenv("GLUESYS_ADDR")
	if addr == "" {
		addr = ":18080"
	}

	http.HandleFunc("/gluesys/prepare", handlePrepare)

	log.Printf("[Gluesys] server listening on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("[Gluesys] server error: %v", err)
	}
}

func handlePrepare(w http.ResponseWriter, r *http.Request) {
	var req GluesysRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	log.Println("==================================================")
	log.Println("[KETI -> Gluesys] Request")
	log.Println("==================================================")
	log.Printf("workload_name : %s", req.WorkloadName)
	log.Printf("dataset_id    : %s", req.DatasetID)
	log.Printf("logical_path  : %s", req.LogicalPath)
	log.Printf("data_locality : %s", req.DataLocality)
	log.Println()
	log.Printf("node_name     : %s", req.NodeName)
	log.Printf("pvc_name      : %s", req.PVCName)
	log.Printf("mount_path    : %s", req.MountPath)

	resp := GluesysResponse{
		Status:       "ready",
		StorageClass: "gluesys-dataset-input",
		DataPath:     "/data/default/" + req.WorkloadName + "/input",
		Message:      "dataset prepared",
	}

	log.Println("==================================================")
	log.Println("[Gluesys -> KETI] Response")
	log.Println("==================================================")
	log.Printf("status        : %s", resp.Status)
	log.Printf("storage_class : %s", resp.StorageClass)
	log.Printf("data_path     : %s", resp.DataPath)
	log.Printf("message       : %s", resp.Message)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

