package main

import (
	"context"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	logger "keti/ai-storage-scheduler/internal/backend/log"
	config "keti/ai-storage-scheduler/internal/config"
	scheduler "keti/ai-storage-scheduler/internal/scheduler"
)

func main() {
	var err error

	config := config.CreateDefaultConfig()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	scheduler.MainScheduler, err = scheduler.NewScheduler(ctx, config)
	if err != nil {
		logger.Error("Failed to generate main sheduler", err)
		os.Exit(1)
	}
	err = scheduler.MainScheduler.InitScheduler()
	if err != nil {
		logger.Error("Failed to initialize main scheduler", err)
		os.Exit(1)
	}

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		logger.Info("Starting main scheduler...")
		scheduler.MainScheduler.Run(ctx)
		logger.Info("Main scheduler stopped")
	}()

	signalChan := make(chan os.Signal, 1)
	signal.Notify(signalChan, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signalChan)

	sig := <-signalChan
	logger.Info("Received signal: %v, shutting down...", sig)

	cancel()

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		logger.Info("All components stopped gracefully")
	case <-time.After(30 * time.Second):
		logger.Warn("Timeout waiting for components to stop")
	}

	logger.Info("Custom scheduler shutdown complete")
	os.Exit(0)
}

package scheduler

import (
	"fmt"

	v1 "k8s.io/api/core/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/tools/cache"
	"k8s.io/klog/v2"

	logger "keti/ai-storage-scheduler/internal/backend/log"
)

func AddAllEventHandlers(
	sched *Scheduler,
	informerFactory informers.SharedInformerFactory,
) error {
	informerFactory.Core().V1().Pods().Informer().AddEventHandler(
		cache.FilteringResourceEventHandler{
			FilterFunc: func(obj any) bool {
				switch t := obj.(type) {
				case *v1.Pod:
					return assignedPod(t) 
				case cache.DeletedFinalStateUnknown:
					if _, ok := t.Obj.(*v1.Pod); ok {
						return true
					}
					return false
				default:
					return false
				}
			},
			Handler: cache.ResourceEventHandlerFuncs{
				AddFunc:    sched.addPodToCache,
				UpdateFunc: sched.updatePodInCache,
				DeleteFunc: sched.deletePodFromCache,
			},
		},
	)

	informerFactory.Core().V1().Pods().Informer().AddEventHandler(
		cache.FilteringResourceEventHandler{
			FilterFunc: func(obj any) bool {
				switch t := obj.(type) {
				case *v1.Pod:
					return !assignedPod(t) && responsibleForPod(t)
				case cache.DeletedFinalStateUnknown:
					return false
				default:
					logger.Warn(fmt.Sprintf("[error] unable to handle object in %T: %T\n", sched, obj))
					return false
				}
			},
			Handler: cache.ResourceEventHandlerFuncs{
				AddFunc:    sched.addPodToSchedulingQueue,
				UpdateFunc: sched.updatePodInSchedulingQueue,
				DeleteFunc: sched.deletePodFromSchedulingQueue,
			},
		},
	)

	informerFactory.Core().V1().Nodes().Informer().AddEventHandler(
		cache.FilteringResourceEventHandler{
			FilterFunc: func(obj any) bool {
				switch obj.(type) {
				case *v1.Node:
					return true
				case cache.DeletedFinalStateUnknown:
					return false
				default:
					logger.Warn(fmt.Sprintf("[error] unable to handle object in %T: %T\n", sched, obj))
					return false
				}
			},
			Handler: cache.ResourceEventHandlerFuncs{
				AddFunc:    sched.addNodeToCache,
				UpdateFunc: sched.updateNodeInCache,
				DeleteFunc: sched.deleteNodeFromCache,
			},
		},
	)

	return nil
}

func (sched *Scheduler) addNodeToCache(obj any) {
	node, ok := obj.(*v1.Node)
	if !ok {
		logger.Warn(fmt.Sprintf("[error] cannot convert to *v1.Node -> %+v", obj))
		return
	}

	logger.Info(fmt.Sprintf("[event] add new node {%s} to cache\n", node.Name))

	err := sched.Cache.AddNode(node, sched.schedulerConfig.HostKubeClient)
	if err != nil {
		klog.ErrorS(nil, "cannot add node [", node.Name, "]")
	}

	sched.SchedulingQueue.MoveAllToActiveOrBackoffQueue()
}

func (sched *Scheduler) updateNodeInCache(oldObj, newObj any) {
	oldNode, ok := oldObj.(*v1.Node)
	if !ok {
		klog.ErrorS(nil, "cannot convert oldObj to *v1.Node", "oldObj", oldObj)
		return
	}

	newNode, ok := newObj.(*v1.Node)
	if !ok {
		klog.ErrorS(nil, "cannot convert newObj to *v1.Node", "newObj", newObj)
		return
	}

	err := sched.Cache.UpdateNode(oldNode, newNode)
	if err != nil {
		klog.ErrorS(nil, "cannot Update Node [", newNode.Name, "]")
	}

	event := NodeSchedulingPropertiesChange(newNode, oldNode)
	if event != nil {
	}
}

func (sched *Scheduler) deleteNodeFromCache(obj any) {
	var node *v1.Node
	switch t := obj.(type) {
	case *v1.Node:
		node = t
	case cache.DeletedFinalStateUnknown:
		var ok bool
		node, ok = t.Obj.(*v1.Node)
		if !ok {
			return
		}
	default:
		return
	}


	if err := sched.Cache.RemoveNode(node); err != nil {
	}
}

func (sched *Scheduler) addPodToSchedulingQueue(obj any) {
	pod := obj.(*v1.Pod)
	sched.SchedulingQueue.Add(pod)
}

func (sched *Scheduler) updatePodInSchedulingQueue(oldObj, newObj any) {
	oldPod, newPod := oldObj.(*v1.Pod), newObj.(*v1.Pod)
	if oldPod.ResourceVersion == newPod.ResourceVersion {
		return
	}

	isAssumed, err := sched.Cache.IsAssumedPod(newPod)
	if err != nil {
	}
	if isAssumed {
		return
	}

	if err := sched.SchedulingQueue.Update(oldPod, newPod); err != nil {
		logger.Warn(fmt.Sprintf("[error] unable to update %T: %v\n", newObj, err))
	}
}

func (sched *Scheduler) deletePodFromSchedulingQueue(obj any) {
	var pod *v1.Pod
	switch t := obj.(type) {
	case *v1.Pod:
		pod = obj.(*v1.Pod)
	case cache.DeletedFinalStateUnknown:
		var ok bool
		pod, ok = t.Obj.(*v1.Pod)
		if !ok {
			logger.Warn(fmt.Sprintf("[error] unable to convert object %T to *v1.Pod in %T\n", obj, sched))
			return
		}
	default:
		logger.Warn(fmt.Sprintf("[error] unable to handle object in %T: %T\n", sched, obj))
		return
	}

	if err := sched.SchedulingQueue.Delete(pod); err != nil {
		logger.Warn(fmt.Sprintf("[error] unable to dequeue %T: %v\n", obj, err))
	}

}

func (sched *Scheduler) addPodToCache(obj any) {
	pod, ok := obj.(*v1.Pod)
	if !ok {
		return
	}

	if err := sched.Cache.AddPod(pod); err != nil {
	}

}

func (sched *Scheduler) updatePodInCache(oldObj, newObj any) {
	oldPod, ok := oldObj.(*v1.Pod)
	if !ok {
		return
	}
	newPod, ok := newObj.(*v1.Pod)
	if !ok {
		return
	}

	if err := sched.Cache.UpdatePod(oldPod, newPod); err != nil {
	}
}

func (sched *Scheduler) deletePodFromCache(obj any) {
	var pod *v1.Pod
	switch t := obj.(type) {
	case *v1.Pod:
		pod = t
	case cache.DeletedFinalStateUnknown:
		var ok bool
		pod, ok = t.Obj.(*v1.Pod)
		if !ok {
			logger.Warn(fmt.Sprintf("cannot convert to *v1.Pod -> %+v", t.Obj))
			return
		}
	default:
		logger.Warn(fmt.Sprintf("cannot convert to *v1.Pod -> %+v", t))
		return
	}

	logger.Info(fmt.Sprintf("[event] delete pod {%s} from cache\n", pod.Name))
	if err := sched.Cache.RemovePod(pod); err != nil {
		klog.ErrorS(err, "[error] scheduler cache remove pod failed", "pod", klog.KObj(pod))
	}

}

func assignedPod(pod *v1.Pod) bool {
	return len(pod.Spec.NodeName) != 0
}

func responsibleForPod(pod *v1.Pod) bool {
	responsibleForPod := (pod.Spec.SchedulerName == "ai-storage-sheduler")
	return responsibleForPod
}

package scheduler

import (
	utils "keti/ai-storage-scheduler/internal/framework/utils"

	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
)

type ActionType int64

const (
	Add ActionType = 1 << iota
	Delete
	UpdateNodeAllocatable
	UpdateNodeLabel
	UpdateNodeTaint
	UpdateNodeCondition
	UpdateNodeAnnotation
	UpdatePodLabel
	UpdatePodScaleDown
	UpdatePodTolerations
	UpdatePodSchedulingGatesEliminated
	UpdatePodGeneratedResourceClaim
	updatePodOther
	All    ActionType = 1<<iota - 1
	Update            = UpdateNodeAllocatable | UpdateNodeLabel | UpdateNodeTaint | UpdateNodeCondition | UpdateNodeAnnotation | UpdatePodLabel | UpdatePodScaleDown | UpdatePodTolerations | UpdatePodSchedulingGatesEliminated | UpdatePodGeneratedResourceClaim | updatePodOther
	none   ActionType = 0
)

func (a ActionType) String() string {
	switch a {
	case Add:
		return "Add"
	case Delete:
		return "Delete"
	case UpdateNodeAllocatable:
		return "UpdateNodeAllocatable"
	case UpdateNodeLabel:
		return "UpdateNodeLabel"
	case UpdateNodeTaint:
		return "UpdateNodeTaint"
	case UpdateNodeCondition:
		return "UpdateNodeCondition"
	case UpdateNodeAnnotation:
		return "UpdateNodeAnnotation"
	case UpdatePodLabel:
		return "UpdatePodLabel"
	case UpdatePodScaleDown:
		return "UpdatePodScaleDown"
	case UpdatePodTolerations:
		return "UpdatePodTolerations"
	case UpdatePodSchedulingGatesEliminated:
		return "UpdatePodSchedulingGatesEliminated"
	case UpdatePodGeneratedResourceClaim:
		return "UpdatePodGeneratedResourceClaim"
	case updatePodOther:
		return "Update"
	case All:
		return "All"
	case Update:
		return "Update"
	}

	return ""
}

var (
	basicActionTypes = []ActionType{Add, Delete, Update}
	podActionTypes = []ActionType{UpdatePodLabel, UpdatePodScaleDown, UpdatePodTolerations, UpdatePodSchedulingGatesEliminated, UpdatePodGeneratedResourceClaim}
	nodeActionTypes = []ActionType{UpdateNodeAllocatable, UpdateNodeLabel, UpdateNodeTaint, UpdateNodeCondition, UpdateNodeAnnotation}
)

type EventResource string

type ClusterEvent struct {
	Resource   EventResource
	ActionType ActionType
	label string
}

const (
	Pod                   EventResource = "Pod"
	AssignedPod           EventResource = "AssignedPod"
	UnschedulablePod      EventResource = "UnschedulablePod"
	Node                  EventResource = "Node"
	PersistentVolume      EventResource = "PersistentVolume"
	PersistentVolumeClaim EventResource = "PersistentVolumeClaim"
	CSINode               EventResource = "storage.k8s.io/CSINode"
	CSIDriver             EventResource = "storage.k8s.io/CSIDriver"
	VolumeAttachment      EventResource = "storage.k8s.io/VolumeAttachment"
	CSIStorageCapacity    EventResource = "storage.k8s.io/CSIStorageCapacity"
	StorageClass          EventResource = "storage.k8s.io/StorageClass"
	ResourceClaim         EventResource = "resource.k8s.io/ResourceClaim"
	ResourceSlice         EventResource = "resource.k8s.io/ResourceSlice"
	DeviceClass           EventResource = "resource.k8s.io/DeviceClass"
	WildCard              EventResource = "*"
)

var (
	allResources = []EventResource{
		Pod,
		AssignedPod,
		UnschedulablePod,
		Node,
		PersistentVolume,
		PersistentVolumeClaim,
		CSINode,
		CSIDriver,
		CSIStorageCapacity,
		StorageClass,
		VolumeAttachment,
		ResourceClaim,
		ResourceSlice,
		DeviceClass,
	}
)

type podChangeExtractor func(newPod *v1.Pod, oldPod *v1.Pod) ActionType

func PodSchedulingPropertiesChange(newPod *v1.Pod, oldPod *v1.Pod) (events []ClusterEvent) {
	r := AssignedPod
	if newPod.Spec.NodeName == "" {
		r = UnschedulablePod
	}

	podChangeExtracters := []podChangeExtractor{
		extractPodLabelsChange,
		extractPodScaleDown,
		extractPodSchedulingGateEliminatedChange,
		extractPodTolerationChange,
	}

	for _, fn := range podChangeExtracters {
		if event := fn(newPod, oldPod); event != none {
			events = append(events, ClusterEvent{Resource: r, ActionType: event})
		}
	}

	if len(events) == 0 {
		events = append(events, ClusterEvent{Resource: r, ActionType: updatePodOther})
	}

	return
}

func extractPodScaleDown(newPod, oldPod *v1.Pod) ActionType {

	newPodRequests := utils.PodRequests(newPod)
	oldPodRequests := utils.PodRequests(oldPod)

	for rName, oldReq := range oldPodRequests {
		newReq, ok := newPodRequests[rName]
		if !ok {
			return UpdatePodScaleDown
		}

		if oldReq.MilliValue() > newReq.MilliValue() {
			return UpdatePodScaleDown
		}
	}

	return none
}

func extractPodLabelsChange(newPod *v1.Pod, oldPod *v1.Pod) ActionType {
	if isLabelChanged(newPod.GetLabels(), oldPod.GetLabels()) {
		return UpdatePodLabel
	}
	return none
}

func isLabelChanged(newLabels map[string]string, oldLabels map[string]string) bool {
	return !equality.Semantic.DeepEqual(newLabels, oldLabels)
}

func extractPodTolerationChange(newPod *v1.Pod, oldPod *v1.Pod) ActionType {
	if len(newPod.Spec.Tolerations) != len(oldPod.Spec.Tolerations) {
		return UpdatePodTolerations
	}

	return none
}

func extractPodSchedulingGateEliminatedChange(newPod *v1.Pod, oldPod *v1.Pod) ActionType {
	if len(newPod.Spec.SchedulingGates) == 0 && len(oldPod.Spec.SchedulingGates) != 0 {
		return UpdatePodSchedulingGatesEliminated
	}

	return none
}

const (
	ScheduleAttemptFailure = "ScheduleAttemptFailure"
	BackoffComplete = "BackoffComplete"
	ForceActivate = "ForceActivate"
	UnschedulableTimeout = "UnschedulableTimeout"
)

var (
	EventAssignedPodAdd = ClusterEvent{Resource: AssignedPod, ActionType: Add}
	EventAssignedPodUpdate = ClusterEvent{Resource: AssignedPod, ActionType: Update}
	EventAssignedPodDelete = ClusterEvent{Resource: AssignedPod, ActionType: Delete}
	EventUnscheduledPodAdd = ClusterEvent{Resource: UnschedulablePod, ActionType: Add}
	EventUnscheduledPodUpdate = ClusterEvent{Resource: UnschedulablePod, ActionType: Update}
	EventUnscheduledPodDelete = ClusterEvent{Resource: UnschedulablePod, ActionType: Delete}
	EventUnschedulableTimeout = ClusterEvent{Resource: WildCard, ActionType: All, label: UnschedulableTimeout}
	EventForceActivate = ClusterEvent{Resource: WildCard, ActionType: All, label: ForceActivate}
)

func NodeSchedulingPropertiesChange(newNode *v1.Node, oldNode *v1.Node) (events []ClusterEvent) {
	nodeChangeExtracters := []nodeChangeExtractor{
		extractNodeSpecUnschedulableChange,
		extractNodeAllocatableChange,
		extractNodeLabelsChange,
		extractNodeTaintsChange,
		extractNodeConditionsChange,
		extractNodeAnnotationsChange,
	}

	for _, fn := range nodeChangeExtracters {
		if event := fn(newNode, oldNode); event != none {
			events = append(events, ClusterEvent{Resource: Node, ActionType: event})
		}
	}
	return
}

type nodeChangeExtractor func(newNode *v1.Node, oldNode *v1.Node) ActionType

func extractNodeAllocatableChange(newNode *v1.Node, oldNode *v1.Node) ActionType {
	if !equality.Semantic.DeepEqual(oldNode.Status.Allocatable, newNode.Status.Allocatable) {
		return UpdateNodeAllocatable
	}
	return none
}

func extractNodeLabelsChange(newNode *v1.Node, oldNode *v1.Node) ActionType {
	if isLabelChanged(newNode.GetLabels(), oldNode.GetLabels()) {
		return UpdateNodeLabel
	}
	return none
}

func extractNodeTaintsChange(newNode *v1.Node, oldNode *v1.Node) ActionType {
	if !equality.Semantic.DeepEqual(newNode.Spec.Taints, oldNode.Spec.Taints) {
		return UpdateNodeTaint
	}
	return none
}

func extractNodeConditionsChange(newNode *v1.Node, oldNode *v1.Node) ActionType {
	strip := func(conditions []v1.NodeCondition) map[v1.NodeConditionType]v1.ConditionStatus {
		conditionStatuses := make(map[v1.NodeConditionType]v1.ConditionStatus, len(conditions))
		for i := range conditions {
			conditionStatuses[conditions[i].Type] = conditions[i].Status
		}
		return conditionStatuses
	}
	if !equality.Semantic.DeepEqual(strip(oldNode.Status.Conditions), strip(newNode.Status.Conditions)) {
		return UpdateNodeCondition
	}
	return none
}

func extractNodeSpecUnschedulableChange(newNode *v1.Node, oldNode *v1.Node) ActionType {
	if newNode.Spec.Unschedulable != oldNode.Spec.Unschedulable && !newNode.Spec.Unschedulable {
		return UpdateNodeTaint
	}
	return none
}

func extractNodeAnnotationsChange(newNode *v1.Node, oldNode *v1.Node) ActionType {
	if !equality.Semantic.DeepEqual(oldNode.GetAnnotations(), newNode.GetAnnotations()) {
		return UpdateNodeAnnotation
	}
	return none
}

package scheduler

import (
	"context"
	"time"

	internalqueue "keti/ai-storage-scheduler/internal/backend/queue"
	framework "keti/ai-storage-scheduler/internal/framework"
	utils "keti/ai-storage-scheduler/internal/framework/utils"

	v1 "k8s.io/api/core/v1"
	"k8s.io/klog/v2"
)

func (sched *Scheduler) ScheduleOne(ctx context.Context) {
	podInfo, err := sched.NextPod()

	if err != nil {
		return
	}

	if podInfo == nil || podInfo.Pod == nil {
		return 
	}

	pod := podInfo.Pod

	fwk, err := sched.frameworkForPod(pod)
	if err != nil {
		sched.SchedulingQueue.Done(pod.UID)
		return
	}


	start := time.Now()

	schedulingCycleCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	scheduleResult, assumedPodInfo, status := sched.schedulingCycle(schedulingCycleCtx, fwk, podInfo, start)
	if !status.IsSuccess() {
		return
	}

	go func() {
		bindingCycleCtx, cancel := context.WithCancel(ctx)
		defer cancel()

		status := sched.bindingCycle(bindingCycleCtx, fwk, scheduleResult, assumedPodInfo, start)
		if !status.IsSuccess() {
			return
		}
	}()
}

func (sched *Scheduler) frameworkForPod(pod *v1.Pod) (framework.Framework, error) {
	var fwk framework.Framework


	return fwk, nil
}

var clearNominatedNode = &NominatingInfo{NominatingMode: ModeOverride, NominatedNodeName: ""}

func (sched *Scheduler) schedulingCycle(
	ctx context.Context,
	fwk framework.Framework,
	podInfo *internalqueue.QueuedPodInfo,
	start time.Time) (ScheduleResult, *internalqueue.QueuedPodInfo, *utils.Status) {

	logger := klog.FromContext(ctx)
	pod := podInfo.Pod

	scheduleResult, err := sched.schedulePod(ctx, fwk, pod)
	if err != nil {
		if err == ErrNoNodesAvailable {
			status := utils.NewStatus(utils.UnschedulableAndUnresolvable).WithError(err)
			return ScheduleResult{nominatingInfo: clearNominatedNode}, podInfo, status
		}

		var nominatingInfo *NominatingInfo
		return ScheduleResult{nominatingInfo: nominatingInfo}, podInfo, utils.NewStatus(utils.Unschedulable).WithError(err)
	}

	assumedPodInfo := podInfo.DeepCopy()
	assumedPod := assumedPodInfo.Pod

	err = sched.assume(logger, assumedPod, scheduleResult.SuggestedHost)
	if err != nil {
		return ScheduleResult{nominatingInfo: clearNominatedNode}, assumedPodInfo, utils.AsStatus(err)
	}

	return scheduleResult, assumedPodInfo, nil
}

func (sched *Scheduler) assume(logger klog.Logger, assumed *v1.Pod, host string) error {
	assumed.Spec.NodeName = host

	if err := sched.Cache.AssumePod(logger, assumed); err != nil {
		logger.Error(err, "Scheduler cache AssumePod failed")
		return err
	}
	if sched.SchedulingQueue != nil {
		sched.SchedulingQueue.DeleteNominatedPodIfExists(assumed)
	}

	return nil
}

func (sched *Scheduler) bindingCycle(
	ctx context.Context,
	fwk framework.Framework,
	scheduleResult ScheduleResult,
	assumedPodInfo *internalqueue.QueuedPodInfo,
	start time.Time) *utils.Status {

	assumedPod := assumedPodInfo.Pod

	err := sched.runBindPlugin(ctx, fwk, assumedPod, &scheduleResult)
	if err != nil {
		// 에러처리
	}

	sched.SchedulingQueue.Done(assumedPod.UID)

	return nil
}

func (sched *Scheduler) schedulePod(ctx context.Context, fwk framework.Framework, pod *v1.Pod) (result ScheduleResult, err error) {
	if sched.Cache.NodeCount() == 0 {
		return result, ErrNoNodesAvailable
	}

	nodes := sched.Cache.Nodes()
	if nodes == nil {
	}
	scheduleResult := NewScheduleResult(nodes)

	err = sched.runFilterPlugin(ctx, fwk, pod, &scheduleResult)
	if err != nil {
		return result, err
	}

	if scheduleResult.FeasibleNodes == 0 {
	} else if scheduleResult.FeasibleNodes == 1 {
		for name, pr := range scheduleResult.PluginResultMap {
			if pr.IsFiltered {
				scheduleResult.SuggestedHost = name
			}
		}
		return scheduleResult, nil
	}

	err = sched.runScorePlugin(ctx, fwk, pod, &scheduleResult)
	if err != nil {
		return result, err
	}

	err = sched.selectResource(pod, &scheduleResult)

	return scheduleResult, err
}

func (sched *Scheduler) runFilterPlugin(ctx context.Context, fwk framework.Framework, pod *v1.Pod, scheduleResult *ScheduleResult) error {
	return nil
}

func (sched *Scheduler) runScorePlugin(ctx context.Context, fwk framework.Framework, pod *v1.Pod, scheduleResult *ScheduleResult) error {
	return nil
}

func (sched *Scheduler) selectResource(pod *v1.Pod, scheduleResult *ScheduleResult) error {
	return nil
}

func (sched *Scheduler) runBindPlugin(ctx context.Context, fwk framework.Framework, assumed *v1.Pod, scheduleResult *ScheduleResult) error {
	defer func() {
		sched.finishBinding(fwk, assumed, scheduleResult.SuggestedHost)
	}()

	return nil
}

func (sched *Scheduler) finishBinding(fwk framework.Framework, assumed *v1.Pod, targetNode string) {
	if finErr := sched.Cache.FinishBinding(assumed); finErr != nil {
	}
}

package scheduler

import (
	"context"
	"fmt"
	logger "keti/ai-storage-scheduler/internal/backend/log"
	internalqueue "keti/ai-storage-scheduler/internal/backend/queue"
	config "keti/ai-storage-scheduler/internal/config"
	framework "keti/ai-storage-scheduler/internal/framework"
	utils "keti/ai-storage-scheduler/internal/framework/utils"
	"sync"

	"k8s.io/apimachinery/pkg/util/wait"
)

var MainScheduler *Scheduler

var ErrNoNodesAvailable = fmt.Errorf("no nodes available to schedule pods")

type Scheduler struct {
	schedulerConfig *config.SchedulerConfig
	Cache           *utils.Cache
	NextPod         func() (*internalqueue.QueuedPodInfo, error)
	StopEverything  <-chan struct{}
	SchedulingQueue *internalqueue.SchedulingQueue
	fwk             framework.Framework
	logger          *logger.Logger
}

type ScheduleResult struct {
	SuggestedHost   string          
	FeasibleNodes   int             
	nominatingInfo  *NominatingInfo 
	PluginResultMap utils.PluginResultMap
}

func NewScheduleResult(nodeInfoMap map[string]*utils.NodeInfo) ScheduleResult {
	pluginResultMap := make(utils.PluginResultMap, len(nodeInfoMap))

	for nodeName, nodeInfo := range nodeInfoMap {
		gpuScores := make(map[string]*utils.GPUScore)

		if nodeInfo != nil && nodeInfo.GPUMap != nil {
			for gpuID := range nodeInfo.GPUMap {
				gpuScores[gpuID] = &utils.GPUScore{}
			}
		}

		pluginResultMap[nodeName] = utils.PluginResult{
			GPUScores:      gpuScores,
			IsFiltered:     false,
			Scores:         make([]utils.PluginScore, 0),
			TotalNodeScore: 0,
		}
	}

	return ScheduleResult{
		SuggestedHost:   "",
		FeasibleNodes:   0,
		nominatingInfo:  nil,
		PluginResultMap: utils.PluginResultMap{},
	}
}

type NominatingMode int

const (
	ModeNoop NominatingMode = iota
	ModeOverride
)

type NominatingInfo struct {
	NominatedNodeName string
	NominatingMode    NominatingMode
}

func NewScheduler(ctx context.Context, cc *config.SchedulerConfig) (*Scheduler, error) {
	stopEverything := ctx.Done()
	schedulerCache := utils.NewCache(ctx)
	podQueue := internalqueue.NewSchedulingQueue(internalqueue.Less, cc.InformerFactory)
	logger := logger.NewLogger(logger.NewDefaultConfig())

	sched := &Scheduler{
		schedulerConfig: cc,
		Cache:           schedulerCache,
		StopEverything:  stopEverything,
		SchedulingQueue: podQueue,
		logger:          logger,
	}

	if err := AddAllEventHandlers(sched, cc.InformerFactory); err != nil {
		return nil, fmt.Errorf("adding event handlers: %w", err)
	}

	sched.NextPod = podQueue.Pop

	return sched, nil
}

func (sched *Scheduler) InitScheduler() error {
	sched.schedulerConfig.InformerFactory.WaitForCacheSync(sched.StopEverything)

	return nil
}

func (sched *Scheduler) Run(ctx context.Context) {
	var internalWG sync.WaitGroup

	internalWG.Add(1)
	go func() {
		defer internalWG.Done()
		sched.schedulerConfig.InformerFactory.Start(ctx.Done())
	}()

	internalWG.Add(1)
	go func() {
		defer internalWG.Done()
		sched.SchedulingQueue.Run()
	}()

	internalWG.Add(1)
	go func() {
		defer internalWG.Done()
		wait.UntilWithContext(ctx, sched.ScheduleOne, 0)
	}()

	<-ctx.Done()
	sched.SchedulingQueue.Close()

	internalWG.Wait()
	logger.Info("All scheduler workers stopped")
}

package framework

import (
	"context"

	utils "keti/ai-storage-scheduler/internal/framework/utils"

	v1 "k8s.io/api/core/v1"
)

type Plugin interface {
	Name() string
}

type FilterPlugin interface {
	Plugin
	Filter(ctx context.Context, pod *v1.Pod, nodeInfo *utils.NodeInfo) *utils.Status
}

type ScorePlugin interface {
	Plugin
	Score(ctx context.Context, pod *v1.Pod, nodeName string) (int64, *utils.Status)
	ScoreExtensions() ScoreExtensions
}

type ScoreExtensions interface {
	NormalizeScore(ctx context.Context, pod *v1.Pod, scores utils.PluginResult) *utils.Status
}

type BindPlugin interface {
	Plugin
	Bind(ctx context.Context, pod *v1.Pod, nodeName string) *utils.Status
}

type Framework interface {
	RunFilterPlugins(ctx context.Context, pod *v1.Pod, nodeInfo *utils.NodeInfo) utils.PluginResultMap
	RunScorePlugins(ctx context.Context, pod *v1.Pod, nodes []*v1.Node) (utils.PluginResultMap, *utils.Status)
	RunBindPlugin(ctx context.Context, pod *v1.Pod, nodeName string) *utils.Status
}
