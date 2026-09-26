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
bash ./scripts/lab.sh create
```

This will:
1. create/reuse the `argocd-lab` kind cluster,
2. install/upgrade ArgoCD via Helm,
3. apply `root-app` to start Git reconciliation from `gitops/root`,
4. verify core readiness.

## Commands
```bash
BOOTSTRAP_REPO_URL="https://github.com/<you>/<repo>.git" bash ./scripts/lab.sh create
bash ./scripts/lab.sh verify
bash ./scripts/lab.sh teardown
```

All commands are safe to run repeatedly.

## Bootstrap overrides (no file edits)
`BOOTSTRAP_REPO_URL` is required and should point to a Git repository ArgoCD can access.
You can override the full bootstrap source without modifying tracked files:

```bash
BOOTSTRAP_REPO_URL="https://github.com/<you>/<fork>.git" \
BOOTSTRAP_REPO_REVISION="<branch>" \
BOOTSTRAP_REPO_PATH="gitops/root" \
./scripts/lab.sh create
```

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
