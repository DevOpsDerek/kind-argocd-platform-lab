#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-argocd-lab}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.31.0}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.11}"
ARGOCD_CHART_REF="${ARGOCD_CHART_REF:-oci://ghcr.io/argoproj/argo-helm/argo-cd}"
BOOTSTRAP_REPO_URL="${BOOTSTRAP_REPO_URL:-}"
BOOTSTRAP_REPO_REVISION="${BOOTSTRAP_REPO_REVISION:-main}"
BOOTSTRAP_REPO_PATH="${BOOTSTRAP_REPO_PATH:-}"
KUBE_CONTEXT="kind-${KIND_CLUSTER_NAME}"
MIN_KIND_VERSION="${MIN_KIND_VERSION:-0.23.0}"
MIN_KUBECTL_VERSION="${MIN_KUBECTL_VERSION:-1.30.0}"
MIN_HELM_VERSION="${MIN_HELM_VERSION:-3.14.0}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

version_gte() {
  local current="$1"
  local required="$2"
  [[ "$(printf "%s\n%s\n" "${required}" "${current}" | sort -V | head -n1)" == "${required}" ]]
}

check_min_version() {
  local tool_name="$1"
  local current="$2"
  local required="$3"
  if ! version_gte "${current}" "${required}"; then
    echo "error: ${tool_name} ${required}+ is required (found ${current})" >&2
    exit 1
  fi
}

kind_cli_version() {
  local output
  output="$(kind version)"

  local parsed
  parsed="$(printf "%s" "${output}" | sed -nE 's/.*kind v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
  if [[ -z "${parsed}" ]]; then
    parsed="$(printf "%s" "${output}" | sed -nE 's/.*v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
  fi
  if [[ -z "${parsed}" ]]; then
    echo "error: unable to parse kind version from: ${output}" >&2
    exit 1
  fi
  printf "%s" "${parsed}"
}

check_prerequisites() {
  require_cmd docker
  require_cmd kind
  require_cmd kubectl
  require_cmd helm

  check_min_version "kind" "$(kind_cli_version)" "${MIN_KIND_VERSION}"
  check_min_version "kubectl" "$(kubectl version --client | sed -n 's/^Client Version: v//p')" "${MIN_KUBECTL_VERSION}"
  check_min_version "helm" "$(helm version --template '{{.Version}}' | sed 's/^v//')" "${MIN_HELM_VERSION}"
}

validate_bootstrap_inputs() {
  if [[ -z "${BOOTSTRAP_REPO_URL}" ]]; then
    echo "error: BOOTSTRAP_REPO_URL is required (set an accessible Git repository URL)" >&2
    exit 1
  fi
  if [[ -z "${BOOTSTRAP_REPO_PATH}" ]]; then
    echo "error: BOOTSTRAP_REPO_PATH is required (set the repo path to bootstrap, for example gitops/root)" >&2
    exit 1
  fi

  for value_name in BOOTSTRAP_REPO_URL BOOTSTRAP_REPO_REVISION BOOTSTRAP_REPO_PATH; do
    local value="${!value_name}"
    if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
      echo "error: ${value_name} must be single-line text" >&2
      exit 1
    fi
  done
}

yaml_escape_single_quoted() {
  sed "s/'/''/g"
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
  kubectl --context "${KUBE_CONTEXT}" create namespace argocd --dry-run=client -o yaml | kubectl --context "${KUBE_CONTEXT}" apply -f -

  helm upgrade --install argocd "${ARGOCD_CHART_REF}" \
    --kube-context "${KUBE_CONTEXT}" \
    --namespace argocd \
    --version "${ARGOCD_CHART_VERSION}" \
    --values "${ROOT_DIR}/helm/argocd-values.yaml" \
    --wait \
    --timeout 10m

  kubectl --context "${KUBE_CONTEXT}" wait \
    --for=condition=Established \
    crd/applications.argoproj.io \
    --timeout=180s
  kubectl --context "${KUBE_CONTEXT}" wait \
    --for=condition=Established \
    crd/appprojects.argoproj.io \
    --timeout=180s

  kubectl --context "${KUBE_CONTEXT}" -n argocd rollout status \
    deploy/argocd-server \
    --timeout=180s
  kubectl --context "${KUBE_CONTEXT}" -n argocd rollout status \
    deploy/argocd-repo-server \
    --timeout=180s
  kubectl --context "${KUBE_CONTEXT}" -n argocd rollout status \
    statefulset/argocd-application-controller \
    --timeout=180s
}

bootstrap_gitops() {
  validate_bootstrap_inputs

  local repo_url_escaped
  local repo_revision_escaped
  local repo_path_escaped
  repo_url_escaped="$(printf "%s" "${BOOTSTRAP_REPO_URL}" | yaml_escape_single_quoted)"
  repo_revision_escaped="$(printf "%s" "${BOOTSTRAP_REPO_REVISION}" | yaml_escape_single_quoted)"
  repo_path_escaped="$(printf "%s" "${BOOTSTRAP_REPO_PATH}" | yaml_escape_single_quoted)"

  kubectl --context "${KUBE_CONTEXT}" apply -f - <<EOF2
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: '${repo_url_escaped}'
    targetRevision: '${repo_revision_escaped}'
    path: '${repo_path_escaped}'
  destination:
    server: https://kubernetes.default.svc
    namespace: platform-system
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

  kubectl --context "${KUBE_CONTEXT}" wait node --all --for=condition=Ready --timeout=180s
  kubectl --context "${KUBE_CONTEXT}" -n argocd rollout status deploy/argocd-server --timeout=180s
  if ! kubectl --context "${KUBE_CONTEXT}" -n argocd get application root-app >/dev/null 2>&1; then
    if [[ -n "${BOOTSTRAP_REPO_URL}" && -n "${BOOTSTRAP_REPO_PATH}" ]]; then
      echo "root-app not found; applying bootstrap application from provided BOOTSTRAP_* inputs"
      bootstrap_gitops
    else
      echo "error: root-app not found. Run create first, or provide BOOTSTRAP_REPO_URL and BOOTSTRAP_REPO_PATH when running verify." >&2
      exit 1
    fi
  fi

  local attempts=60
  local sync_status=""
  local health_status=""
  local managed_resource_ready="false"
  while (( attempts > 0 )); do
    sync_status="$(kubectl --context "${KUBE_CONTEXT}" -n argocd get application root-app -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health_status="$(kubectl --context "${KUBE_CONTEXT}" -n argocd get application root-app -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if kubectl --context "${KUBE_CONTEXT}" -n platform-system get configmap platform-lab-info >/dev/null 2>&1; then
      managed_resource_ready="true"
    else
      managed_resource_ready="false"
    fi

    if [[ "${sync_status}" == "Synced" && "${health_status}" == "Healthy" && "${managed_resource_ready}" == "true" ]]; then
      echo "root-app is Synced and Healthy; managed platform resource is present"
      echo "verification complete"
      return
    fi

    attempts=$(( attempts - 1 ))
    sleep 5
  done

  echo "error: verification timed out (sync=${sync_status:-unknown}, health=${health_status:-unknown}, platform_configmap=${managed_resource_ready})" >&2
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
    check_prerequisites
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
