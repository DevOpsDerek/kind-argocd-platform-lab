#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-argocd-lab}"
KUBE_CONTEXT="kind-${KIND_CLUSTER_NAME}"

kubectl --context "${KUBE_CONTEXT}" -n argocd \
  wait --for=jsonpath='{.status.sync.status}'=Synced application/kyverno --timeout=180s
kubectl --context "${KUBE_CONTEXT}" -n argocd \
  wait --for=jsonpath='{.status.health.status}'=Healthy application/kyverno --timeout=180s
kubectl --context "${KUBE_CONTEXT}" -n kyverno \
  rollout status deployment/kyverno-admission-controller --timeout=180s
kubectl --context "${KUBE_CONTEXT}" \
  wait --for=jsonpath='{.status.ready}'=true \
  clusterpolicies.kyverno.io/require-non-root-and-no-privileged \
  clusterpolicies.kyverno.io/require-resources-in-tenant-namespaces \
  --timeout=180s

kubectl --context "${KUBE_CONTEXT}" apply --dry-run=server \
  -f "${ROOT_DIR}/gitops/platform/examples/kyverno-allow-pod.yaml"

expect_policy_rejection() {
  local manifest="$1"
  local expected_message="$2"
  local diagnostic

  if diagnostic="$(kubectl --context "${KUBE_CONTEXT}" apply --dry-run=server -f "${ROOT_DIR}/${manifest}" 2>&1)"; then
    printf 'error: expected %s to be rejected, but it was admitted\n%s\n' "${manifest}" "${diagnostic}" >&2
    return 1
  fi

  printf '%s\n' "${diagnostic}"
  if [[ "${diagnostic}" != *"${expected_message}"* ]]; then
    printf 'error: %s failed without the expected Kyverno diagnostic: %s\n' "${manifest}" "${expected_message}" >&2
    return 1
  fi

  printf 'expected policy rejection confirmed: %s\n' "${manifest}"
}

expect_policy_rejection \
  "gitops/platform/examples/kyverno-deny-privileged-pod.yaml" \
  "Privileged containers are not allowed in tenant namespaces"
expect_policy_rejection \
  "gitops/platform/examples/kyverno-deny-missing-resources-pod.yaml" \
  "Pods in tenant namespaces must declare cpu/memory requests and limits"
