// Package policyagent는 OrchestrationPolicy 실행 전 정책 평가 클라이언트를 제공한다.
// Created: 2026-05-22
package policyagent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// Policy는 Policy Agent 평가에 필요한 독립 정책 표현이다.
type Policy struct {
	APIVersion string         `json:"apiVersion,omitempty"`
	Kind       string         `json:"kind,omitempty"`
	Metadata   PolicyMetadata `json:"metadata,omitempty"`
	Spec       PolicySpec     `json:"spec,omitempty"`
}

// PolicyMetadata는 선택적 식별 정보를 담는다.
type PolicyMetadata struct {
	Name      string `json:"name,omitempty"`
	Namespace string `json:"namespace,omitempty"`
}

// PolicySpec는 Policy Agent가 평가하는 정책 스펙이다.
type PolicySpec struct {
	PolicyType      string            `json:"policyType,omitempty"`
	Probability     int32             `json:"probability,omitempty"`
	Urgency         string            `json:"urgency,omitempty"`
	ResourceType    string            `json:"resourceType,omitempty"`
	TargetNode      string            `json:"targetNode,omitempty"`
	SourceNode      string            `json:"sourceNode,omitempty"`
	TargetWorkload  string            `json:"targetWorkload,omitempty"`
	TargetNamespace string            `json:"targetNamespace,omitempty"`
	Reason          string            `json:"reason,omitempty"`
	Horizon         int32             `json:"horizon,omitempty"`
	AutoExecute     bool              `json:"autoExecute,omitempty"`
	PriorityScore   int32             `json:"priorityScore,omitempty"`
	Parameters      map[string]string `json:"parameters,omitempty"`
}

// DecisionType은 Policy Agent가 반환하는 정책 처리 방향이다.
type DecisionType string

const (
	DecisionApprove DecisionType = "approve"
	DecisionDelay   DecisionType = "delay"
	DecisionReject  DecisionType = "reject"
	DecisionModify  DecisionType = "modify"
)

// Decision은 Policy Agent 평가 결과와 선택적 보정 내용을 담는다.
type Decision struct {
	Action       DecisionType      `json:"action"`
	Reason       string            `json:"reason,omitempty"`
	RequeueAfter time.Duration     `json:"-"`
	ModifiedSpec *PolicySpec       `json:"modifiedSpec,omitempty"`
	Parameters   map[string]string `json:"parameters,omitempty"`
}

// Client는 HTTP Policy Agent와 rule-based fallback을 함께 제공한다.
type Client struct {
	baseURL      string
	httpClient   *http.Client
	requeueAfter time.Duration
}

// NewClient는 Policy Agent 클라이언트를 생성한다.
func NewClient(baseURL string, timeout, requeueAfter time.Duration) *Client {
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	if requeueAfter <= 0 {
		requeueAfter = 30 * time.Second
	}
	return &Client{
		baseURL: strings.TrimRight(strings.TrimSpace(baseURL), "/"),
		httpClient: &http.Client{
			Timeout: timeout,
		},
		requeueAfter: requeueAfter,
	}
}

// Evaluate는 정책을 평가하고 approve/delay/reject/modify 중 하나를 반환한다.
func (c *Client) Evaluate(ctx context.Context, policy *Policy) (Decision, error) {
	if c == nil {
		return RuleBasedEvaluate(policy, 30*time.Second), nil
	}
	if c.baseURL == "" {
		return RuleBasedEvaluate(policy, c.requeueAfter), nil
	}

	decision, err := c.evaluateHTTP(ctx, policy)
	if err != nil {
		return Decision{}, err
	}
	if !decision.Action.Valid() {
		return Decision{}, fmt.Errorf("unknown policy agent decision: %s", decision.Action)
	}
	if decision.RequeueAfter <= 0 {
		decision.RequeueAfter = c.requeueAfter
	}
	return decision, nil
}

func (c *Client) evaluateHTTP(ctx context.Context, policy *Policy) (Decision, error) {
	body, err := json.Marshal(policy)
	if err != nil {
		return Decision{}, fmt.Errorf("failed to encode policy agent request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/evaluate", bytes.NewReader(body))
	if err != nil {
		return Decision{}, fmt.Errorf("failed to create policy agent request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return Decision{}, fmt.Errorf("failed to call policy agent: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return Decision{}, fmt.Errorf("policy agent returned status %d", resp.StatusCode)
	}

	var decision Decision
	if err := json.NewDecoder(resp.Body).Decode(&decision); err != nil {
		return Decision{}, fmt.Errorf("failed to decode policy agent response: %w", err)
	}
	return decision, nil
}

// RuleBasedEvaluate는 기본 규칙으로 정책 효율성과 위험도를 평가한다.
func RuleBasedEvaluate(policy *Policy, requeueAfter time.Duration) Decision {
	if requeueAfter <= 0 {
		requeueAfter = 30 * time.Second
	}
	const (
		rejectProbabilityThreshold    int32 = 40
		proactiveProbabilityThreshold int32 = 45
		standardProbabilityThreshold  int32 = 50
		minApprovalPriorityScore      int32 = 80
		highApprovalPriorityScore     int32 = 84
	)
	if strings.TrimSpace(policy.Spec.TargetWorkload) == "" {
		return Decision{Action: DecisionReject, Reason: "targetWorkload is required"}
	}
	if policy.Spec.PolicyType == "migration" &&
		strings.TrimSpace(policy.Spec.SourceNode) != "" &&
		strings.TrimSpace(policy.Spec.SourceNode) == strings.TrimSpace(policy.Spec.TargetNode) {
		return Decision{Action: DecisionReject, Reason: "migration sourceNode and targetNode are identical"}
	}
	if policy.Spec.Probability < rejectProbabilityThreshold {
		return Decision{Action: DecisionReject, Reason: "probability is below policy agent reject threshold"}
	}
	if policy.Spec.Urgency == "CRITICAL" && policy.Spec.PriorityScore < minApprovalPriorityScore {
		modified := policy.Spec
		modified.Parameters = copyParameters(policy.Spec.Parameters)
		modified.PriorityScore = minApprovalPriorityScore
		modified.Parameters["policyAgentModified"] = "true"
		return Decision{
			Action:       DecisionModify,
			Reason:       "critical policy priorityScore aligned with forecaster severity",
			ModifiedSpec: &modified,
		}
	}
	if policy.Spec.Urgency == "CRITICAL" {
		return Decision{Action: DecisionApprove, Reason: "critical urgency approved"}
	}
	if policy.Spec.Urgency == "HIGH" && policy.Spec.PriorityScore >= highApprovalPriorityScore {
		return Decision{Action: DecisionApprove, Reason: "high urgency with sufficient priorityScore approved"}
	}
	if policy.Spec.PriorityScore >= highApprovalPriorityScore && policy.Spec.Probability >= proactiveProbabilityThreshold {
		return Decision{Action: DecisionApprove, Reason: "forecaster priorityScore supports proactive approval"}
	}
	if policy.Spec.PriorityScore >= minApprovalPriorityScore && policy.Spec.Probability >= standardProbabilityThreshold {
		return Decision{Action: DecisionApprove, Reason: "priorityScore and probability meet standard approval threshold"}
	}
	return Decision{
		Action:       DecisionDelay,
		Reason:       "policy remains below forecaster-aligned approval threshold",
		RequeueAfter: requeueAfter,
	}
}

func copyParameters(params map[string]string) map[string]string {
	copied := map[string]string{}
	for key, value := range params {
		copied[key] = value
	}
	return copied
}

// Valid는 decision action이 지원되는 값인지 확인한다.
func (d DecisionType) Valid() bool {
	switch d {
	case DecisionApprove, DecisionDelay, DecisionReject, DecisionModify:
		return true
	default:
		return false
	}
}
