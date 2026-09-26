#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-argocd-lab}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.31.0}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.11}"
BOOTSTRAP_REPO_URL="${BOOTSTRAP_REPO_URL:-https://github.com/DevOpsDerek/kind-argocd-platform-lab.git}"
BOOTSTRAP_REPO_REVISION="${BOOTSTRAP_REPO_REVISION:-main}"
BOOTSTRAP_REPO_PATH="${BOOTSTRAP_REPO_PATH:-gitops/root}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

check_prerequisites() {
  require_cmd docker
  require_cmd kind
  require_cmd kubectl
  require_cmd helm
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "${KIND_CLUSTER_NAME}"
}

create_cluster() {
  if cluster_exists; then
    echo "kind cluster '${KIND_CLUSTER_NAME}' already exists; skipping cluster creation"
    return
  fi

  kind create cluster \
    --name "${KIND_CLUSTER_NAME}" \
    --config "${ROOT_DIR}/kind/kind-config.yaml" \
    --image "${KIND_NODE_IMAGE}"
}

install_argocd() {
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm repo update >/dev/null

  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --version "${ARGOCD_CHART_VERSION}" \
    --values "${ROOT_DIR}/helm/argocd-values.yaml" \
    --wait \
    --timeout 10m
}

bootstrap_gitops() {
  kubectl apply -f - <<EOF2
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${BOOTSTRAP_REPO_URL}
    targetRevision: ${BOOTSTRAP_REPO_REVISION}
    path: ${BOOTSTRAP_REPO_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF2
}

verify_lab() {
  if ! cluster_exists; then
    echo "error: kind cluster '${KIND_CLUSTER_NAME}' does not exist" >&2
    exit 1
  fi

  kubectl wait node --all --for=condition=Ready --timeout=180s
  kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
  kubectl -n argocd get application root-app >/dev/null

  local attempts=60
  local sync_status=""
  local health_status=""
  while (( attempts > 0 )); do
    sync_status="$(kubectl -n argocd get application root-app -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health_status="$(kubectl -n argocd get application root-app -o jsonpath='{.status.health.status}' 2>/dev/null || true)"

    if [[ "${sync_status}" == "Synced" && "${health_status}" == "Healthy" ]]; then
      echo "root-app is Synced and Healthy"
      echo "verification complete"
      return
    fi

    attempts=$(( attempts - 1 ))
    sleep 5
  done

  echo "error: root-app did not become Synced/Healthy (sync=${sync_status:-unknown}, health=${health_status:-unknown})" >&2
  exit 1
}

teardown_lab() {
  if ! cluster_exists; then
    echo "kind cluster '${KIND_CLUSTER_NAME}' not found; nothing to tear down"
    return
  fi

  kind delete cluster --name "${KIND_CLUSTER_NAME}"
}

create_lab() {
  check_prerequisites
  create_cluster
  install_argocd
  bootstrap_gitops
  verify_lab
}

usage() {
  cat <<EOF2
Usage: $(basename "$0") <create|verify|teardown>

Commands:
  create    Create (or reconcile) kind + ArgoCD lab and bootstrap GitOps
  verify    Verify cluster and ArgoCD/root-app health
  teardown  Delete the kind cluster
EOF2
}

case "${1:-}" in
  create)
    create_lab
    ;;
  verify)
    check_prerequisites
    verify_lab
    ;;
  teardown)
    check_prerequisites
    teardown_lab
    ;;
  *)
    usage
    exit 1
    ;;
esac
