// Package cachelocality는 노드 로컬(또는 뷰 마운트) 캐시 디렉터리를 스캔해
// DataLocalityAware 플러그인의 캐시 점수 산출에 필요한 정보를 제공한다.
//
// Author: 미정 <unknown>
// Created: 2026-04-16
package cachelocality

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	v1 "k8s.io/api/core/v1"

	"golang.org/x/sys/unix"
)

// 오케스트레이터(ai-storage-orchestrator) prefetch가 사용하는 기본 캐시 루트와 동일하다.
const DefaultCacheRoot = "/tmp/ai-storage-cache"

// EnvNodeCacheViewRoot는 스케줄러가 각 워커 노드의 캐시 트리를 읽을 수 있도록
// 호스트 경로를 노드별로 거울 복제해 둔 상위 디렉터리다.
// 예: /mnt/cache-views → 실제 검사 경로는 filepath.Join(Env, nodeName) 이다.
const EnvNodeCacheViewRoot = "KETI_NODE_CACHE_VIEW_ROOT"

// AnnotPrefetchSourcePath는 샤드가 읽을 데이터셋 루트(워커 노드 기준 절대 경로)를 나타낸다.
// 값이 없으면 파일 적중률은 산출하지 않고 용량 점수만 반영한다.
const AnnotPrefetchSourcePath = "ai-storage.keti/prefetch-source-path"

const labelShardIndex = "ai-storage.keti/shard-index"
const labelShardCount = "ai-storage.keti/shard-count"

const prefetchNextShardDir = "_prefetch_next_shard"

// ScoreInput은 캐시 점수 계산에 필요한 상한과 가중치를 담는다.
type ScoreInput struct {
	MaxScore int64
	// HitWeight는 MaxScore 중 파일 적중에 배분할 비율(0~1)이다.
	HitWeight float64
	// CapacityWeight는 MaxScore 중 여유 공간(headroom)에 배분할 비율(0~1)이다.
	CapacityWeight float64
}

// DefaultScoreInput은 ShardAware 점수와 겹치지 않도록 캐시 항목만 분리해 가중치를 나눈다.
func DefaultScoreInput(maxScore int64) ScoreInput {
	return ScoreInput{
		MaxScore:       maxScore,
		HitWeight:      0.65,
		CapacityWeight: 0.35,
	}
}

// ScoreResult는 점수와 진단 문자열을 담는다.
type ScoreResult struct {
	Score       int64
	Source      string
	Warn        error
	HitRatio    float64
	Occupancy   float64
	CacheUsed   int64
	CacheAvail  uint64
	RequiredCnt int
	HitCnt      int
}

// ScoreForPod는 주어진 노드에서 보이는 캐시 디렉터리를 기준으로 점수를 계산한다.
//
// 노드별 캐시를 읽을 수 없으면 Err가 설정되고 Score는 중립(MaxScore/2)이다.
func ScoreForPod(pod *v1.Pod, nodeName string, in ScoreInput) ScoreResult {
	out := ScoreResult{Source: "filesystem-cache"}
	if in.MaxScore <= 0 {
		out.Score = 0
		out.Source = "disabled-maxScore=0"
		return out
	}
	neutral := in.MaxScore / 2

	base, err := resolveCacheBase(nodeName)
	if err != nil {
		out.Score = neutral
		out.Warn = err
		out.Source = "NEUTRAL-cache-view-unavailable"
		return out
	}

	jobDirs, err := listCacheJobDirs(base)
	if err != nil {
		out.Score = neutral
		out.Warn = fmt.Errorf("cachelocality: list cache jobs under %q: %w", base, err)
		out.Source = "NEUTRAL-cache-list-error"
		return out
	}

	used, err := bytesUnderJobDirs(base, jobDirs)
	if err != nil {
		out.Score = neutral
		out.Warn = fmt.Errorf("cachelocality: measure cache usage: %w", err)
		out.Source = "NEUTRAL-cache-usage-error"
		return out
	}
	out.CacheUsed = used

	avail, serr := statfsAvailable(base)
	if serr != nil {
		out.Score = neutral
		out.Warn = fmt.Errorf("cachelocality: statfs %q: %w", base, serr)
		out.Source = "NEUTRAL-statfs-error"
		return out
	}
	out.CacheAvail = avail

	denom := float64(used) + float64(avail)
	if denom <= 0 {
		out.Occupancy = 0
	} else {
		out.Occupancy = float64(used) / denom
		if out.Occupancy < 0 {
			out.Occupancy = 0
		}
		if out.Occupancy > 1 {
			out.Occupancy = 1
		}
	}

	dsRoot := prefetchDatasetRoot(pod)
	var hitRatio float64
	var reqN, hitN int
	if dsRoot != "" {
		files, lerr := listRegularFilesSorted(dsRoot)
		if lerr != nil {
			out.Warn = fmt.Errorf("cachelocality: list dataset %q: %w", dsRoot, lerr)
			out.Source = "filesystem-cache;dataset-walk-error"
		} else {
			idx, total := shardIndexAndTotal(pod)
			req := filesAssignedToShard(files, idx, total)
			reqN = len(req)
			for _, abs := range req {
				rel, e := filepath.Rel(dsRoot, abs)
				if e != nil || strings.HasPrefix(rel, "..") {
					continue
				}
				if cacheContainsRel(base, jobDirs, rel) {
					hitN++
				}
			}
			if reqN > 0 {
				hitRatio = float64(hitN) / float64(reqN)
			}
		}
	}
	out.HitRatio = hitRatio
	out.RequiredCnt = reqN
	out.HitCnt = hitN

	hitPart := int64(float64(in.MaxScore) * in.HitWeight * hitRatio)
	headroom := 1.0 - out.Occupancy
	capPart := int64(float64(in.MaxScore) * in.CapacityWeight * headroom)
	score := hitPart + capPart
	if score > in.MaxScore {
		score = in.MaxScore
	}
	if score < 0 {
		score = 0
	}
	out.Score = score
	out.Source = fmt.Sprintf("filesystem-cache(hit=%d/%d,occ=%.3f,used=%d,avail=%d)",
		hitN, reqN, out.Occupancy, used, avail)
	return out
}

func resolveCacheBase(nodeName string) (string, error) {
	if root := strings.TrimSpace(os.Getenv(EnvNodeCacheViewRoot)); root != "" {
		base := filepath.Join(root, nodeName)
		fi, err := os.Stat(base)
		if err != nil {
			return "", fmt.Errorf("%s=%q node %q: stat %q: %w", EnvNodeCacheViewRoot, root, nodeName, base, err)
		}
		if !fi.IsDir() {
			return "", fmt.Errorf("%s node path %q is not a directory", nodeName, base)
		}
		return filepath.Clean(base), nil
	}
	host, herr := os.Hostname()
	if herr != nil {
		return "", fmt.Errorf("hostname: %w", herr)
	}
	if !hostMatchesNode(host, nodeName) {
		return "", fmt.Errorf("cache view root unset and scheduler host %q != node %q (set %s)",
			host, nodeName, EnvNodeCacheViewRoot)
	}
	fi, err := os.Stat(DefaultCacheRoot)
	if err != nil {
		return "", fmt.Errorf("stat default cache %q: %w", DefaultCacheRoot, err)
	}
	if !fi.IsDir() {
		return "", fmt.Errorf("default cache path %q is not a directory", DefaultCacheRoot)
	}
	return DefaultCacheRoot, nil
}

func hostMatchesNode(host, nodeName string) bool {
	if host == nodeName {
		return true
	}
	if i := strings.IndexByte(host, '.'); i > 0 && host[:i] == nodeName {
		return true
	}
	return false
}

func listCacheJobDirs(base string) ([]string, error) {
	ents, err := os.ReadDir(base)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasPrefix(name, "cache-") {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out, nil
}

func bytesUnderJobDirs(base string, jobDirs []string) (int64, error) {
	var sum int64
	for _, j := range jobDirs {
		root := filepath.Join(base, j)
		err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				return nil
			}
			info, err := d.Info()
			if err != nil {
				return err
			}
			if !info.Mode().IsRegular() {
				return nil
			}
			sum += info.Size()
			return nil
		})
		if err != nil {
			return sum, err
		}
	}
	return sum, nil
}

func statfsAvailable(path string) (uint64, error) {
	var st unix.Statfs_t
	if err := unix.Statfs(path, &st); err != nil {
		return 0, err
	}
	return uint64(st.Bavail) * uint64(st.Bsize), nil
}

func prefetchDatasetRoot(pod *v1.Pod) string {
	if pod == nil || pod.Annotations == nil {
		return ""
	}
	return strings.TrimSpace(pod.Annotations[AnnotPrefetchSourcePath])
}

func shardIndexAndTotal(pod *v1.Pod) (idx, total int) {
	idx, total = 0, 1
	if pod == nil {
		return
	}
	if pod.Labels != nil {
		if v, ok := pod.Labels["apps.kubernetes.io/pod-index"]; ok {
			if n, e := strconv.Atoi(strings.TrimSpace(v)); e == nil && n >= 0 {
				idx = n
			}
		}
		if v, ok := pod.Labels[labelShardIndex]; ok {
			if n, e := strconv.Atoi(strings.TrimSpace(v)); e == nil && n >= 0 {
				idx = n
			}
		}
		if v, ok := pod.Labels[labelShardCount]; ok {
			if n, e := strconv.Atoi(strings.TrimSpace(v)); e == nil && n > 0 {
				total = n
			}
		}
	}
	if pod.Annotations != nil {
		if v := pod.Annotations[labelShardIndex]; v != "" {
			if n, e := strconv.Atoi(strings.TrimSpace(v)); e == nil && n >= 0 {
				idx = n
			}
		}
		if v := pod.Annotations[labelShardCount]; v != "" {
			if n, e := strconv.Atoi(strings.TrimSpace(v)); e == nil && n > 0 {
				total = n
			}
		}
	}
	if total < 1 {
		total = 1
	}
	idx = ((idx % total) + total) % total
	return idx, total
}

// filesAssignedToShard는 정렬된 절대 경로 목록을 샤드 수로 나눈 부분집합을 반환한다(오케스트레이터와 동일 규칙).
func filesAssignedToShard(sortedAbs []string, shardIdx, totalShards int) []string {
	if totalShards < 1 {
		totalShards = 1
	}
	shardIdx = ((shardIdx % totalShards) + totalShards) % totalShards
	var out []string
	for i, p := range sortedAbs {
		if i%totalShards == shardIdx {
			out = append(out, p)
		}
	}
	return out
}

func listRegularFilesSorted(root string) ([]string, error) {
	fi, err := os.Stat(root)
	if err != nil {
		return nil, err
	}
	if !fi.IsDir() {
		if fi.Mode().IsRegular() {
			return []string{filepath.Clean(root)}, nil
		}
		return nil, fmt.Errorf("dataset root %q is not a directory or regular file", root)
	}
	rootClean := filepath.Clean(root)
	var out []string
	err = filepath.WalkDir(rootClean, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		out = append(out, path)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}

func cacheContainsRel(base string, jobDirs []string, rel string) bool {
	for _, j := range jobDirs {
		candidates := []string{
			filepath.Join(base, j, rel),
			filepath.Join(base, j, prefetchNextShardDir, rel),
		}
		for _, p := range candidates {
			if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() {
				return true
			}
		}
	}
	return false
}
