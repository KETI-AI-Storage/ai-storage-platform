// Package cachelocality 테스트.
//
// Author: 미정 <unknown>
// Created: 2026-04-16
package cachelocality

import (
	"os"
	"path/filepath"
	"testing"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestScoreForPod_CacheHitAndShard(t *testing.T) {
	view := t.TempDir()
	nodeName := "worker-test-1"
	nodeBase := filepath.Join(view, nodeName)
	if err := os.MkdirAll(filepath.Join(nodeBase, "cache-job1"), 0o755); err != nil {
		t.Fatal(err)
	}
	dataset := filepath.Join(t.TempDir(), "dataset")
	if err := os.MkdirAll(filepath.Join(dataset, "p", "q"), 0o755); err != nil {
		t.Fatal(err)
	}
	// 세 파일: 샤드 2개일 때 인덱스 0은 정렬상 0,2번째 파일
	files := []string{
		filepath.Join(dataset, "a.txt"),
		filepath.Join(dataset, "p", "b.txt"),
		filepath.Join(dataset, "p", "q", "c.txt"),
	}
	for _, f := range files {
		if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// 캐시에는 샤드 0이 필요로 하는 a.txt, p/q/c.txt 만 적재
	if err := os.WriteFile(filepath.Join(nodeBase, "cache-job1", "a.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(nodeBase, "cache-job1", "p", "q"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nodeBase, "cache-job1", "p", "q", "c.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv(EnvNodeCacheViewRoot, view)

	pod := &v1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Annotations: map[string]string{
				AnnotPrefetchSourcePath: dataset,
			},
			Labels: map[string]string{
				labelShardIndex: "0",
				labelShardCount: "2",
			},
		},
	}

	res := ScoreForPod(pod, nodeName, DefaultScoreInput(100))
	if res.Warn != nil {
		t.Fatalf("unexpected warn: %v", res.Warn)
	}
	if res.RequiredCnt != 2 {
		t.Fatalf("required=%d want 2", res.RequiredCnt)
	}
	if res.HitCnt != 2 {
		t.Fatalf("hits=%d want 2", res.HitCnt)
	}
	if res.HitRatio < 0.99 {
		t.Fatalf("hitRatio=%v want ~1", res.HitRatio)
	}
	if res.Score < 50 {
		t.Fatalf("score=%d expected high", res.Score)
	}
}

func TestScoreForPod_NeutralWhenNoView(t *testing.T) {
	_ = os.Unsetenv(EnvNodeCacheViewRoot)
	pod := &v1.Pod{ObjectMeta: metav1.ObjectMeta{Name: "p"}}
	res := ScoreForPod(pod, "definitely-not-this-hosts-node-name-xyz", DefaultScoreInput(20))
	if res.Warn == nil {
		t.Fatal("expected warn when view unavailable")
	}
	if res.Score != 10 {
		t.Fatalf("neutral want 10 got %d", res.Score)
	}
}

func TestScoreForPod_NextShardDir(t *testing.T) {
	view := t.TempDir()
	nodeName := "n1"
	nodeBase := filepath.Join(view, nodeName)
	dataset := filepath.Join(t.TempDir(), "ds2")
	if err := os.MkdirAll(dataset, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dataset, "only.txt"), []byte("ab"), 0o644); err != nil {
		t.Fatal(err)
	}
	nextDir := filepath.Join(nodeBase, "cache-x", prefetchNextShardDir)
	if err := os.MkdirAll(nextDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nextDir, "only.txt"), []byte("ab"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv(EnvNodeCacheViewRoot, view)
	pod := &v1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Annotations: map[string]string{AnnotPrefetchSourcePath: dataset},
			Labels:      map[string]string{labelShardCount: "1"},
		},
	}
	res := ScoreForPod(pod, nodeName, DefaultScoreInput(40))
	if res.Warn != nil {
		t.Fatalf("warn: %v", res.Warn)
	}
	if res.HitCnt != 1 || res.RequiredCnt != 1 {
		t.Fatalf("hits required %d/%d", res.HitCnt, res.RequiredCnt)
	}
}
