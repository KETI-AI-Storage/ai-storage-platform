// Package plugin는 AI 스토리지 스케줄러 플러그인을 제공한다.
//
// Author: 미정 <unknown>
// Created: 2026-04-21
package plugin

import (
	"context"
	"fmt"
	"hash/fnv"
	"sort"
	"strconv"
	"strings"

	framework "keti/ai-storage-scheduler/internal/framework"
	utils "keti/ai-storage-scheduler/internal/framework/utils"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

const ShardAwareName = "ShardAware"

// ShardAware는 샤드 워크로드(STS·pod-index·scope shard-index)에 대해
// PVC→PV 접근 가능 노드 집합을 만든 뒤 shard-index로 노드를 고르고,
// 동일 노드로의 샤드 몰림을 피한다. ai-storage.keti/shard-nodes는 사용하지 않는다.
type ShardAware struct {
	cache      *utils.Cache
	kubeClient kubernetes.Interface
}

var _ framework.FilterPlugin = &ShardAware{}
var _ framework.ScorePlugin = &ShardAware{}

// NewShardAware는 shard-aware 플러그인을 생성한다.
func NewShardAware(cache *utils.Cache, kubeClient kubernetes.Interface) *ShardAware {
	return &ShardAware{cache: cache, kubeClient: kubeClient}
}

func (s *ShardAware) Name() string {
	return ShardAwareName
}

// Filter는 (1) 모든 PVC 접근 가능 (2) 다중 PVC 시 분산 대상 노드와 일치하는지 검사한다.
func (s *ShardAware) Filter(ctx context.Context, pod *v1.Pod, nodeInfo *utils.NodeInfo) *utils.Status {
	if nodeInfo == nil || nodeInfo.Node() == nil {
		return utils.NewStatus(utils.Error, "node not found")
	}
	if !shardWorkloadWithPVC(pod) {
		return utils.NewStatus(utils.Success, "")
	}
	if s.kubeClient == nil {
		return utils.NewStatus(utils.Success, "")
	}
	node := nodeInfo.Node()
	for _, vol := range pod.Spec.Volumes {
		if vol.PersistentVolumeClaim == nil {
			continue
		}
		name := vol.PersistentVolumeClaim.ClaimName
		if !s.canAccessPVCOnNode(ctx, pod.Namespace, name, node.Name) {
			return utils.NewStatus(utils.Unschedulable,
				"shard workload: PVC %s is not accessible from node %s", name, node.Name)
		}
	}

	feasible, usedFallback := s.feasibleNodesForShardPod(ctx, pod)
	if len(feasible) == 0 {
		return utils.NewStatus(utils.Unschedulable, "shard: no cache node can access all workload PVCs")
	}
	target := s.pickShardTargetNode(feasible, shardIndexFromPod(pod), pod)
	if len(feasible) > 1 && node.Name != target {
		fb := ""
		if usedFallback {
			fb = "; used PVC-accessible union fallback"
		}
		return utils.NewStatus(utils.Unschedulable,
			fmt.Sprintf("shard distribution: shard-index maps to node %s (not %s); feasible=%d%s",
				target, node.Name, len(feasible), fb))
	}
	return utils.NewStatus(utils.Success, "")
}

// Score는 PVC 로컬리티·토폴로지 점수에 분산 대상 노드 가산을 더한다.
func (s *ShardAware) Score(ctx context.Context, pod *v1.Pod, nodeName string) (int64, *utils.Status) {
	if !shardWorkloadWithPVC(pod) {
		return 50, utils.NewStatus(utils.Success, "")
	}
	if s.kubeClient == nil {
		return 50, utils.NewStatus(utils.Success, "")
	}
	nodeInfo := s.cache.Nodes()[nodeName]
	if nodeInfo == nil || nodeInfo.Node() == nil {
		return 0, utils.NewStatus(utils.Error, "node not found in cache")
	}
	node := nodeInfo.Node()

	var sum int64
	var n int64
	for _, vol := range pod.Spec.Volumes {
		if vol.PersistentVolumeClaim == nil {
			continue
		}
		pvcName := vol.PersistentVolumeClaim.ClaimName
		local := s.isPVCLocalToNode(ctx, pod.Namespace, pvcName, node.Name)
		access := s.canAccessPVCOnNode(ctx, pod.Namespace, pvcName, node.Name)
		topo := s.pvTopologyMatchesNode(ctx, pod.Namespace, pvcName, node)
		var sc int64
		switch {
		case local && topo:
			sc = 100
		case local:
			sc = 85
		case access:
			sc = 45
		default:
			sc = 0
		}
		sum += sc
		n++
	}
	if n == 0 {
		return 50, utils.NewStatus(utils.Success, "")
	}
	localityAvg := sum / n

	feasible, _ := s.feasibleNodesForShardPod(ctx, pod)
	if len(feasible) <= 1 {
		return localityAvg, utils.NewStatus(utils.Success, "")
	}
	target := s.pickShardTargetNode(feasible, shardIndexFromPod(pod), pod)
	if nodeName == target {
		// 분산 대상 + 로컬리티 결합(상한 100 근처 유지)
		bonus := int64(35)
		if localityAvg+bonus > 100 {
			return 100, utils.NewStatus(utils.Success, "")
		}
		return localityAvg + bonus, utils.NewStatus(utils.Success, "")
	}
	// 필터를 통과한 비대상 노드(드문 설정)에 낮은 가산
	if localityAvg > 25 {
		return localityAvg / 4, utils.NewStatus(utils.Success, "")
	}
	return 10, utils.NewStatus(utils.Success, "")
}

func (s *ShardAware) ScoreExtensions() framework.ScoreExtensions {
	return s
}

func (s *ShardAware) NormalizeScore(ctx context.Context, pod *v1.Pod, scores utils.PluginResult) *utils.Status {
	return utils.NewStatus(utils.Success, "")
}

// feasibleNodesForShardPod는 PVC별 접근 가능 노드의 교집합(정렬)을 반환한다.
// 교집합이 비면 PVC별 접근 가능 노드의 합집합으로 축소한다(fallback).
func (s *ShardAware) feasibleNodesForShardPod(ctx context.Context, pod *v1.Pod) (sorted []string, usedUnionFallback bool) {
	pvcs := pvcNamesFromPod(pod)
	if len(pvcs) == 0 {
		return nil, false
	}
	inter := s.nodesAccessAllPVCs(ctx, pod.Namespace, pvcs)
	if len(inter) > 0 {
		return inter, false
	}
	union := s.nodesAccessAnyPVC(ctx, pod.Namespace, pvcs)
	return union, len(union) > 0
}

func pvcNamesFromPod(pod *v1.Pod) []string {
	var out []string
	for _, vol := range pod.Spec.Volumes {
		if vol.PersistentVolumeClaim != nil {
			out = append(out, vol.PersistentVolumeClaim.ClaimName)
		}
	}
	return out
}

func (s *ShardAware) nodesAccessAllPVCs(ctx context.Context, namespace string, pvcs []string) []string {
	var common map[string]struct{}
	for i, pvc := range pvcs {
		set := s.nodesAccessSinglePVC(ctx, namespace, pvc)
		if i == 0 {
			common = set
			continue
		}
		for n := range common {
			if _, ok := set[n]; !ok {
				delete(common, n)
			}
		}
	}
	return sortedNodeNames(common)
}

func (s *ShardAware) nodesAccessAnyPVC(ctx context.Context, namespace string, pvcs []string) []string {
	union := make(map[string]struct{})
	for _, pvc := range pvcs {
		for n := range s.nodesAccessSinglePVC(ctx, namespace, pvc) {
			union[n] = struct{}{}
		}
	}
	return sortedNodeNames(union)
}

func (s *ShardAware) nodesAccessSinglePVC(ctx context.Context, namespace, pvc string) map[string]struct{} {
	out := make(map[string]struct{})
	for name := range s.cache.Nodes() {
		if s.canAccessPVCOnNode(ctx, namespace, pvc, name) {
			out[name] = struct{}{}
		}
	}
	return out
}

func sortedNodeNames(m map[string]struct{}) []string {
	if len(m) == 0 {
		return nil
	}
	names := make([]string, 0, len(m))
	for n := range m {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// pickShardTargetNode는 기본으로 feasible[shardIndex % len]을 쓰고,
// shardIndex < 0일 때만 FNV(pod UID) % len으로 인덱스를 만든다.
func (s *ShardAware) pickShardTargetNode(feasible []string, shardIdx int, pod *v1.Pod) string {
	if len(feasible) == 0 {
		return ""
	}
	if len(feasible) == 1 {
		return feasible[0]
	}
	idx := shardIdx % len(feasible)
	if shardIdx < 0 {
		h := fnv.New32a()
		_, _ = h.Write([]byte(string(pod.UID)))
		idx = int(h.Sum32()) % len(feasible)
	}
	return feasible[idx]
}

// shardIndexFromPod는 STS 라벨·scope shard-index에서 샤드 인덱스를 읽는다.
func shardIndexFromPod(pod *v1.Pod) int {
	if pod == nil {
		return 0
	}
	if pod.Labels != nil {
		if v, ok := pod.Labels["apps.kubernetes.io/pod-index"]; ok {
			if i, err := strconv.Atoi(v); err == nil {
				return i
			}
		}
	}
	if pod.Annotations != nil {
		if v := pod.Annotations["ai-storage.keti/shard-index"]; v != "" {
			if i, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
				return i
			}
		}
	}
	if pod.Labels != nil {
		if name, ok := pod.Labels["statefulset.kubernetes.io/pod-name"]; ok {
			if ord, ok2 := parseStatefulSetOrdinal(name); ok2 {
				return ord
			}
		}
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(string(pod.UID)))
	return int(h.Sum32())
}

func parseStatefulSetOrdinal(podFullName string) (int, bool) {
	i := strings.LastIndex(podFullName, "-")
	if i < 0 || i >= len(podFullName)-1 {
		return 0, false
	}
	ord, err := strconv.Atoi(podFullName[i+1:])
	return ord, err == nil
}

// isShardIndexedWorkload는 trace/scope·STS가 남긴 샤드 식별 정보가 있는지 본다.
func isShardIndexedWorkload(pod *v1.Pod) bool {
	if pod == nil {
		return false
	}
	if pod.Labels != nil {
		if _, ok := pod.Labels["apps.kubernetes.io/pod-index"]; ok {
			return true
		}
		if _, ok := pod.Labels["statefulset.kubernetes.io/pod-name"]; ok {
			return true
		}
	}
	if pod.Annotations != nil {
		if v := pod.Annotations["ai-storage.keti/shard-index"]; v != "" {
			if _, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
				return true
			}
		}
	}
	return false
}

func shardWorkloadWithPVC(pod *v1.Pod) bool {
	if !isShardIndexedWorkload(pod) {
		return false
	}
	for _, v := range pod.Spec.Volumes {
		if v.PersistentVolumeClaim != nil {
			return true
		}
	}
	return false
}

func (s *ShardAware) canAccessPVCOnNode(ctx context.Context, namespace, pvcName, nodeName string) bool {
	if s.kubeClient == nil {
		return true
	}
	pvc, err := s.kubeClient.CoreV1().PersistentVolumeClaims(namespace).Get(ctx, pvcName, metav1.GetOptions{})
	if err != nil {
		return true
	}
	for _, am := range pvc.Spec.AccessModes {
		if am == v1.ReadWriteMany || am == v1.ReadOnlyMany {
			return true
		}
	}
	if pvc.Status.Phase == v1.ClaimBound {
		return s.isPVCLocalToNode(ctx, namespace, pvcName, nodeName)
	}
	return true
}

func (s *ShardAware) isPVCLocalToNode(ctx context.Context, namespace, pvcName, nodeName string) bool {
	if s.kubeClient == nil {
		return false
	}
	pvc, err := s.kubeClient.CoreV1().PersistentVolumeClaims(namespace).Get(ctx, pvcName, metav1.GetOptions{})
	if err != nil || pvc.Status.Phase != v1.ClaimBound || pvc.Spec.VolumeName == "" {
		return false
	}
	pv, err := s.kubeClient.CoreV1().PersistentVolumes().Get(ctx, pvc.Spec.VolumeName, metav1.GetOptions{})
	if err != nil {
		return false
	}
	if pv.Spec.NodeAffinity != nil && pv.Spec.NodeAffinity.Required != nil {
		for _, term := range pv.Spec.NodeAffinity.Required.NodeSelectorTerms {
			for _, expr := range term.MatchExpressions {
				if expr.Key == "kubernetes.io/hostname" {
					for _, value := range expr.Values {
						if value == nodeName {
							return true
						}
					}
				}
			}
		}
	}
	if pv.Spec.Local != nil && pv.Spec.NodeAffinity != nil && pv.Spec.NodeAffinity.Required != nil {
		for _, term := range pv.Spec.NodeAffinity.Required.NodeSelectorTerms {
			for _, expr := range term.MatchExpressions {
				if expr.Key == "kubernetes.io/hostname" {
					for _, value := range expr.Values {
						if value == nodeName {
							return true
						}
					}
				}
			}
		}
	}
	return false
}

// pvTopologyMatchesNode는 PV 라벨 zone과 노드 zone 일치 여부를 본다.
func (s *ShardAware) pvTopologyMatchesNode(ctx context.Context, namespace, pvcName string, node *v1.Node) bool {
	if s.kubeClient == nil || node.Labels == nil {
		return false
	}
	pvc, err := s.kubeClient.CoreV1().PersistentVolumeClaims(namespace).Get(ctx, pvcName, metav1.GetOptions{})
	if err != nil || pvc.Spec.VolumeName == "" {
		return false
	}
	pv, err := s.kubeClient.CoreV1().PersistentVolumes().Get(ctx, pvc.Spec.VolumeName, metav1.GetOptions{})
	if err != nil {
		return false
	}
	if pv.Labels != nil {
		for _, zk := range []string{"topology.kubernetes.io/zone", "failure-domain.beta.kubernetes.io/zone"} {
			if zpv, ok := pv.Labels[zk]; ok && zpv != "" {
				if znode := node.Labels[zk]; znode != "" && zpv == znode {
					return true
				}
			}
		}
	}
	return false
}
