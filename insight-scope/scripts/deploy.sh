#!/bin/bash

# Insight Scope Deploy Script
# KETI APOLLO System

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEPLOY_DIR="$PROJECT_DIR/deployments"

ACTION="${1:-apply}"

echo "=============================================="
echo "  Insight Scope - Deploy Script"
echo "  KETI APOLLO System Component"
echo "=============================================="

cd "$PROJECT_DIR"

case "$ACTION" in
    apply|a)
        echo ""
        echo "Deploying Insight Scope..."
        kubectl apply -f "$DEPLOY_DIR/insight-scope.yaml"

        echo ""
        echo "Waiting for deployment to be ready..."
        kubectl rollout status deployment/insight-scope -n keti --timeout=120s

        echo ""
        echo "=============================================="
        echo "  Deployment Complete!"
        echo "=============================================="
        echo ""
        echo "Insight Scope is running in the 'keti' namespace"
        echo ""
        echo "To access the API:"
        echo "  kubectl port-forward -n keti svc/insight-scope 8081:8081"
        echo ""
        echo "Test endpoints:"
        echo "  curl http://localhost:8081/health"
        echo "  curl http://localhost:8081/api/v1/models"
        echo "  curl http://localhost:8081/api/v1/models/search?q=bert"
        ;;

    delete|d)
        echo ""
        echo "Deleting Insight Scope..."
        kubectl delete -f "$DEPLOY_DIR/insight-scope.yaml" --ignore-not-found

        echo ""
        echo "Insight Scope deleted"
        ;;

    status|s)
        echo ""
        echo "Insight Scope Status:"
        kubectl get deployment,svc,pod -n keti -l app=insight-scope
        ;;

    logs|l)
        echo ""
        echo "Insight Scope Logs:"
        kubectl logs -n keti -l app=insight-scope -f
        ;;

    *)
        echo "Usage: $0 {apply|delete|status|logs}"
        echo ""
        echo "Commands:"
        echo "  apply, a   - Deploy Insight Scope"
        echo "  delete, d  - Delete Insight Scope"
        echo "  status, s  - Show status"
        echo "  logs, l    - View logs"
        exit 1
        ;;
esac
