# kind + ArgoCD Platform Lab

This repository bootstraps a reproducible local GitOps lab on [kind](https://kind.sigs.k8s.io/) using Helm-installed ArgoCD.

## What this provides
- Idempotent lab lifecycle commands: create, verify, teardown.
- Pinned local runtime and ArgoCD chart/image versions.
- GitOps bootstrap (`root-app`) that reconciles further platform components from this repo.
- No tracked-file edits required for clean setup (use environment overrides instead).

## Prerequisites
Install these tools on your machine:
- Docker Engine (running)
- kind `>= 0.23`
- kubectl `>= 1.30`
- Helm `>= 3.14`

Recommended minimum host resources for smooth local use:
- 4 CPU
- 8 GB RAM
- 20 GB free disk

## Pinned versions
- kind node image: `kindest/node:v1.31.0`
- ArgoCD Helm chart reference: `oci://ghcr.io/argoproj/argo-helm/argo-cd` + version `7.7.11`
- ArgoCD component images: chart defaults from pinned chart `7.7.11` (kept in sync)

## Quick start (clean setup)
From the repository root:

```bash
BOOTSTRAP_REPO_URL="https://github.com/<you>/<repo>.git" \
BOOTSTRAP_REPO_PATH="gitops/root" \
bash ./scripts/lab.sh create
```

This will:
1. create/reuse the `argocd-lab` kind cluster,
2. install/upgrade ArgoCD via Helm,
3. apply `root-app` to start Git reconciliation from `gitops/root`,
4. verify core readiness.

## Commands
```bash
BOOTSTRAP_REPO_URL="https://github.com/<you>/<repo>.git" BOOTSTRAP_REPO_PATH="gitops/root" bash ./scripts/lab.sh create
bash ./scripts/lab.sh verify
bash ./scripts/lab.sh teardown
```

`verify` is intended to run after `create`, because it checks the bootstrapped `root-app`.
If `root-app` is missing, run `verify` with `BOOTSTRAP_REPO_URL` and `BOOTSTRAP_REPO_PATH` to re-apply bootstrap.

All commands are safe to run repeatedly.

## Bootstrap overrides (no file edits)
`BOOTSTRAP_REPO_URL` and `BOOTSTRAP_REPO_PATH` are required.
`BOOTSTRAP_REPO_URL` should point to a Git repository ArgoCD can access, and `BOOTSTRAP_REPO_PATH` should be the root-app path in that repo.
You can override the full bootstrap source without modifying tracked files:

```bash
BOOTSTRAP_REPO_URL="https://github.com/<you>/<fork>.git" \
BOOTSTRAP_REPO_REVISION="<branch>" \
BOOTSTRAP_REPO_PATH="gitops/root" \
./scripts/lab.sh create
```

## Namespace tenancy controls (BG-008)
The platform base now defines two synthetic tenant namespaces:
- `tenant-a`
- `tenant-b`

Each tenant namespace gets:
- dedicated `tenant-admin` ServiceAccount + Role/RoleBinding scoped only to its own namespace
- `ResourceQuota` (`tenant-quota`)
- `LimitRange` (`tenant-defaults`)
- ingress `NetworkPolicy` defaults that allow same-namespace traffic but deny cross-namespace ingress

Kyverno is installed by ArgoCD as a managed Helm chart (`kyverno` Application in `argocd`) and enforces tenant workload guardrails:
- privileged containers are denied
- `spec.securityContext.runAsNonRoot=true` is required
- CPU/memory requests and limits are required

### Reproducible verification checks
Run these after `bash ./scripts/lab.sh create` completes and ArgoCD has synced.

1. Confirm tenant resources exist:
```bash
kubectl get ns tenant-a tenant-b
kubectl -n tenant-a get sa tenant-admin resourcequota tenant-quota limitrange tenant-defaults
kubectl -n tenant-b get sa tenant-admin resourcequota tenant-quota limitrange tenant-defaults
```

2. Confirm RBAC separation:
```bash
kubectl auth can-i --as=system:serviceaccount:tenant-a:tenant-admin create pods -n tenant-a
kubectl auth can-i --as=system:serviceaccount:tenant-a:tenant-admin create pods -n tenant-b
kubectl auth can-i --as=system:serviceaccount:tenant-b:tenant-admin create pods -n tenant-b
kubectl auth can-i --as=system:serviceaccount:tenant-b:tenant-admin create pods -n tenant-a
```
Expected: `yes`, `no`, `yes`, `no`.

3. Confirm Kyverno allow + deny behavior:
```bash
kubectl apply --dry-run=server -f gitops/platform/examples/kyverno-allow-pod.yaml
kubectl apply --dry-run=server -f gitops/platform/examples/kyverno-deny-privileged-pod.yaml
kubectl apply --dry-run=server -f gitops/platform/examples/kyverno-deny-missing-resources-pod.yaml
```
Expected: allow manifest succeeds; deny manifests are rejected by Kyverno validation.

4. Confirm tenant workloads can be created with the enforced Pod policy:
```bash
kubectl -n tenant-a run tenant-a-echo --image=hashicorp/http-echo:1.0 --labels app=echo --port=5678 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true},"containers":[{"name":"tenant-a-echo","resources":{"requests":{"cpu":"100m","memory":"128Mi"},"limits":{"cpu":"200m","memory":"256Mi"}}}]}}' \
  -- -text=tenant-a
kubectl -n tenant-a wait --for=condition=Ready pod/tenant-a-echo --timeout=120s

kubectl -n tenant-b run tenant-b-echo --image=hashicorp/http-echo:1.0 --labels app=echo --port=5678 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true},"containers":[{"name":"tenant-b-echo","resources":{"requests":{"cpu":"100m","memory":"128Mi"},"limits":{"cpu":"200m","memory":"256Mi"}}}]}}' \
  -- -text=tenant-b
kubectl -n tenant-b wait --for=condition=Ready pod/tenant-b-echo --timeout=120s
```
Expected: both Pods become Ready. This demonstrates policy-compliant tenant workloads; NetworkPolicy enforcement is not included because kind's default `kindnet` CNI does not enforce NetworkPolicy objects.

### Isolation caveat
These namespace controls demonstrate practical RBAC and admission guardrails for a local lab, but they are **not hard isolation** and are **not equivalent to dedicated clusters**. Cluster-scoped components, node/kernel sharing, and control-plane trust boundaries remain shared.

## OpenTelemetry observability (BG-009)
The platform deploys a pinned Prometheus/Grafana stack and OpenTelemetry Collector through ArgoCD. Two `telemetrygen` workloads continuously send sample traces and metrics over OTLP to the collector. Prometheus scrapes collector pipeline metrics and exported OTLP metrics; Grafana provisions a telemetry pipeline dashboard with signal throughput and export-failure panels.

After `bash ./scripts/lab.sh create` completes and the ArgoCD Applications are healthy, follow the [observability runbook](docs/observability-runbook.md) to verify signal flow, inspect the dashboard, and troubleshoot failures. The path is local-only: traces are written to the collector debug output, and no Azure account, credentials, or live Azure services are required. The runbook maps these signals to Azure Monitor and Application Insights concepts.

## Secret handling
Do **not** commit plaintext secrets.

Recommended approaches:
- SOPS + age/GPG (encrypted manifests in Git)
- Sealed Secrets
- External Secrets Operator with external secret stores

For local testing, pass sensitive values at runtime (environment variables, local files ignored by git), not as tracked manifests.

## Local lab vs production AKS limitations
This lab is for reproducible local workflows, not production parity. Main differences:
- Single-node kind cluster (no AKS control-plane/data-plane SLA behavior)
- No managed cloud integrations (Azure CNI, Key Vault CSI, managed identity, Azure LB/WAF)
- Reduced security/compliance posture compared to hardened production clusters
- Local Docker networking and storage characteristics differ from AKS

Use this lab for fast iteration and GitOps validation; validate production-specific behavior in AKS environments.
