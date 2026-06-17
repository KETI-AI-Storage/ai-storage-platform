package analyzer

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"

	"insight-scope/pkg/types"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// DAGAnalyzer analyzes Argo Workflow DAG structure
type DAGAnalyzer struct {
	dynamicClient dynamic.Interface
	stageKeywords map[types.PipelineStage][]string
}

// ArgoWorkflowGVR is the GroupVersionResource for Argo Workflows
var ArgoWorkflowGVR = schema.GroupVersionResource{
	Group:    "argoproj.io",
	Version:  "v1alpha1",
	Resource: "workflows",
}

// NewDAGAnalyzer creates a new DAG analyzer
func NewDAGAnalyzer(kubeconfig string) (*DAGAnalyzer, error) {
	var config *rest.Config
	var err error

	if kubeconfig != "" {
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
	} else {
		config, err = rest.InClusterConfig()
	}
	if err != nil {
		return nil, fmt.Errorf("failed to create kubernetes config: %w", err)
	}

	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create dynamic client: %w", err)
	}

	analyzer := &DAGAnalyzer{
		dynamicClient: dynamicClient,
		stageKeywords: make(map[types.PipelineStage][]string),
	}
	analyzer.initStageKeywords()

	return analyzer, nil
}

func (da *DAGAnalyzer) initStageKeywords() {
	da.stageKeywords[types.StagePreprocesing] = []string{
		"preprocess", "preprocessing", "prepare", "etl", "transform",
		"augment", "resize", "normalize", "tokenize", "encode", "data",
	}
	da.stageKeywords[types.StageTraining] = []string{
		"train", "training", "fit", "learn", "finetune", "fine-tune",
		"pytorch", "tensorflow", "model",
	}
	da.stageKeywords[types.StageEvaluation] = []string{
		"eval", "evaluate", "evaluation", "test", "validate", "validation",
		"benchmark", "score", "metric",
	}
	da.stageKeywords[types.StageInference] = []string{
		"infer", "inference", "predict", "serve", "serving", "deploy",
	}
}

// AnalyzeFromPod analyzes DAG from pod labels
func (da *DAGAnalyzer) AnalyzeFromPod(ctx context.Context, podLabels map[string]string, namespace string) *types.DAGAnalysis {
	// Get workflow name from pod label
	workflowName := podLabels["workflows.argoproj.io/workflow"]
	if workflowName == "" {
		log.Printf("DAG Analysis: No workflow label found")
		return nil
	}

	// Get current node/step name (this might be in annotations, but we'll try labels first)
	currentStep := podLabels["workflows.argoproj.io/node-name"]

	return da.AnalyzeWorkflow(ctx, workflowName, namespace, currentStep)
}

// AnalyzeWorkflow analyzes an Argo Workflow by name
func (da *DAGAnalyzer) AnalyzeWorkflow(ctx context.Context, workflowName, namespace, currentStep string) *types.DAGAnalysis {
	result := &types.DAGAnalysis{
		WorkflowName:      workflowName,
		WorkflowNamespace: namespace,
		Steps:             make([]types.DAGStep, 0),
		DataFlow:          make([]types.DataFlowEdge, 0),
		ExecutionHistory:  make([]types.StepExecution, 0),
	}

	// Fetch workflow resource
	workflow, err := da.dynamicClient.Resource(ArgoWorkflowGVR).Namespace(namespace).Get(ctx, workflowName, metav1.GetOptions{})
	if err != nil {
		log.Printf("DAG Analysis: Failed to get workflow %s: %v", workflowName, err)
		return result
	}

	// Parse DAG structure
	da.parseDAGStructure(workflow, result)

	// Parse execution status
	da.parseExecutionStatus(workflow, result)

	// Determine current step
	if currentStep != "" {
		// Extract step name from node-name (format: "workflow-name.step-name")
		parts := strings.Split(currentStep, ".")
		if len(parts) > 1 {
			result.CurrentStep = parts[len(parts)-1]
		} else {
			result.CurrentStep = currentStep
		}
	}

	// Find current step index
	for i, step := range result.Steps {
		if step.Name == result.CurrentStep {
			result.CurrentStepIndex = i
			break
		}
	}

	// Infer pipeline characteristics
	da.inferPipelineCharacteristics(result)

	// Build data flow edges
	da.buildDataFlow(result)

	log.Printf("DAG Analysis: Analyzed workflow %s with %d steps, current: %s",
		workflowName, result.TotalSteps, result.CurrentStep)

	return result
}

// parseDAGStructure parses the DAG structure from workflow spec
func (da *DAGAnalyzer) parseDAGStructure(workflow *unstructured.Unstructured, result *types.DAGAnalysis) {
	spec, found, _ := unstructured.NestedMap(workflow.Object, "spec")
	if !found {
		return
	}

	templates, found, _ := unstructured.NestedSlice(spec, "templates")
	if !found {
		return
	}

	// Find the DAG template
	for _, tmpl := range templates {
		tmplMap, ok := tmpl.(map[string]interface{})
		if !ok {
			continue
		}

		dag, found, _ := unstructured.NestedMap(tmplMap, "dag")
		if !found {
			continue
		}

		tasks, found, _ := unstructured.NestedSlice(dag, "tasks")
		if !found {
			continue
		}

		// Parse each task
		for _, task := range tasks {
			taskMap, ok := task.(map[string]interface{})
			if !ok {
				continue
			}

			step := types.DAGStep{
				Name:     getStringField(taskMap, "name"),
				Template: getStringField(taskMap, "template"),
			}

			// Parse dependencies
			if deps, found, _ := unstructured.NestedStringSlice(taskMap, "dependencies"); found {
				step.Dependencies = deps
			}

			// Infer step type from name
			step.StepType = da.inferStepType(step.Name, step.Template)
			step.IOPattern = da.inferStepIOPattern(step.StepType)
			step.EstimatedIOGB = da.estimateStepIO(step.StepType)

			result.Steps = append(result.Steps, step)
		}

		result.TotalSteps = len(result.Steps)

		// Calculate parallelism level
		result.ParallelismLevel = da.calculateParallelism(result.Steps)
		break
	}
}

// parseExecutionStatus parses workflow execution status
func (da *DAGAnalyzer) parseExecutionStatus(workflow *unstructured.Unstructured, result *types.DAGAnalysis) {
	status, found, _ := unstructured.NestedMap(workflow.Object, "status")
	if !found {
		return
	}

	nodes, found, _ := unstructured.NestedMap(status, "nodes")
	if !found {
		return
	}

	// Update step phases and build execution history
	for _, node := range nodes {
		nodeMap, ok := node.(map[string]interface{})
		if !ok {
			continue
		}

		nodeName := getStringField(nodeMap, "displayName")
		phase := getStringField(nodeMap, "phase")
		startedAt := getStringField(nodeMap, "startedAt")
		finishedAt := getStringField(nodeMap, "finishedAt")

		// Update step phase
		for i := range result.Steps {
			if result.Steps[i].Name == nodeName {
				result.Steps[i].Phase = phase
				break
			}
		}

		// Add to execution history if it's a task node
		nodeType := getStringField(nodeMap, "type")
		if nodeType == "Pod" || nodeType == "Skipped" {
			exec := types.StepExecution{
				StepName:  nodeName,
				StartTime: startedAt,
				EndTime:   finishedAt,
				Status:    phase,
			}
			result.ExecutionHistory = append(result.ExecutionHistory, exec)
		}
	}
}

// inferStepType infers the pipeline stage from step name
func (da *DAGAnalyzer) inferStepType(name, template string) types.PipelineStage {
	nameLower := strings.ToLower(name + " " + template)

	for stage, keywords := range da.stageKeywords {
		for _, kw := range keywords {
			if strings.Contains(nameLower, kw) {
				return stage
			}
		}
	}

	return types.StageUnknown
}

// inferStepIOPattern infers I/O pattern based on step type
func (da *DAGAnalyzer) inferStepIOPattern(stepType types.PipelineStage) types.IOPattern {
	switch stepType {
	case types.StagePreprocesing:
		return types.IOPatternSequentialRead // Read raw data, write processed
	case types.StageTraining:
		return types.IOPatternBalanced // Read data, write checkpoints
	case types.StageEvaluation:
		return types.IOPatternSequentialRead // Read model and test data
	case types.StageInference:
		return types.IOPatternRandomRead // Random access for serving
	default:
		return types.IOPatternBalanced
	}
}

// estimateStepIO estimates I/O volume for a step type
func (da *DAGAnalyzer) estimateStepIO(stepType types.PipelineStage) float64 {
	switch stepType {
	case types.StagePreprocesing:
		return 50.0 // GB - data transformation
	case types.StageTraining:
		return 200.0 // GB - model + checkpoints + data
	case types.StageEvaluation:
		return 30.0 // GB - model + test data
	case types.StageInference:
		return 10.0 // GB - model loading
	default:
		return 20.0
	}
}

// calculateParallelism calculates the maximum parallelism level in DAG
func (da *DAGAnalyzer) calculateParallelism(steps []types.DAGStep) int {
	if len(steps) == 0 {
		return 0
	}

	// Simple calculation: count steps that can run in parallel
	// (steps with same dependencies or no dependencies)
	depCount := make(map[int]int) // dependency count -> number of steps

	for _, step := range steps {
		depCount[len(step.Dependencies)]++
	}

	maxParallel := 0
	for _, count := range depCount {
		if count > maxParallel {
			maxParallel = count
		}
	}

	return maxParallel
}

// inferPipelineCharacteristics infers overall pipeline characteristics
func (da *DAGAnalyzer) inferPipelineCharacteristics(result *types.DAGAnalysis) {
	// Count step types
	stageCount := make(map[types.PipelineStage]int)
	var totalIO float64

	for _, step := range result.Steps {
		stageCount[step.StepType]++
		totalIO += step.EstimatedIOGB
	}

	result.EstimatedTotalIOGB = totalIO

	// Infer pipeline type based on step composition
	if stageCount[types.StageTraining] > 0 {
		result.InferredPipelineType = "training"
		result.InferredDataPattern = types.IOPatternSequentialRead
	} else if stageCount[types.StageInference] > 0 {
		result.InferredPipelineType = "inference"
		result.InferredDataPattern = types.IOPatternRandomRead
	} else if stageCount[types.StagePreprocesing] > 0 {
		result.InferredPipelineType = "etl"
		result.InferredDataPattern = types.IOPatternSequentialRead
	} else {
		result.InferredPipelineType = "unknown"
		result.InferredDataPattern = types.IOPatternBalanced
	}
}

// buildDataFlow builds data flow edges between steps
func (da *DAGAnalyzer) buildDataFlow(result *types.DAGAnalysis) {
	for _, step := range result.Steps {
		for _, dep := range step.Dependencies {
			edge := types.DataFlowEdge{
				FromStep: dep,
				ToStep:   step.Name,
			}

			// Infer data type based on step types
			fromStep := da.findStep(result.Steps, dep)
			if fromStep != nil {
				switch fromStep.StepType {
				case types.StagePreprocesing:
					edge.DataType = "processed_data"
					edge.EstimatedSizeGB = 50.0
				case types.StageTraining:
					edge.DataType = "model_checkpoint"
					edge.EstimatedSizeGB = 10.0
				default:
					edge.DataType = "intermediate"
					edge.EstimatedSizeGB = 20.0
				}
			}

			result.DataFlow = append(result.DataFlow, edge)
		}
	}
}

// findStep finds a step by name
func (da *DAGAnalyzer) findStep(steps []types.DAGStep, name string) *types.DAGStep {
	for i := range steps {
		if steps[i].Name == name {
			return &steps[i]
		}
	}
	return nil
}

// Helper function to get string field from map
func getStringField(m map[string]interface{}, key string) string {
	if val, ok := m[key]; ok {
		if str, ok := val.(string); ok {
			return str
		}
	}
	return ""
}

// ToJSON converts DAGAnalysis to JSON string
func (da *DAGAnalyzer) ToJSON(analysis *types.DAGAnalysis) string {
	data, err := json.MarshalIndent(analysis, "", "  ")
	if err != nil {
		return "{}"
	}
	return string(data)
}
