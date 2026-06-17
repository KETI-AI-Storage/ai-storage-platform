// Package volumes defines multi-PVC mount layout (data / checkpoint / cache / output).
// Each path may be backed by a different Kubernetes StorageClass.
package volumes

import (
	"fmt"
	"os"
)

// Layout is the container filesystem layout for tiered storage.
type Layout struct {
	// Data: 메타데이터·SQLite 등 영구 메타 저장
	Data string
	// Checkpoint: 마이그레이션/학습 체크포인트 등 대용량 스냅샷
	Checkpoint string
	// Cache: 재계산 가능한 임시·캐시 데이터
	Cache string
	// Output: 추론·리포트 등 결과물
	Output string
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// FromEnv reads mount paths. Defaults match Kubernetes volumeMount paths in deployments.
func FromEnv() Layout {
	return Layout{
		Data:       getenv("DATA_DIR", "/data"),
		Checkpoint: getenv("CHECKPOINT_DIR", "/checkpoint"),
		Cache:      getenv("CACHE_DIR", "/cache"),
		Output:     getenv("OUTPUT_DIR", "/output"),
	}
}

// EnsureWorkDirs creates top-level directories on writable PVCs (emptyDir mounts start empty).
func (l Layout) EnsureWorkDirs() error {
	for name, d := range map[string]string{
		"checkpoint": l.Checkpoint,
		"cache":      l.Cache,
		"output":     l.Output,
	} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return fmt.Errorf("mkdir %s (%s): %w", name, d, err)
		}
	}
	return nil
}
