---
name: code-review
description: Review pull requests and changes in this kind/ArgoCD GitOps lab, including cluster lifecycle, manifests, Helm/Kustomize, Argo CD, and GitHub Actions. Use when asked to review a PR, issue, diff, or branch in this repository.
---

# Code review for the kind/ArgoCD platform lab

This skill applies to this local GitOps lab. Base repository-specific policy
claims on files that actually exist; do not assume this repository has a
`GOVERNANCE.md` or `CODEOWNERS` file.

## 1. Understand intent before judging changes

- Read the linked issue and the PR title and description. Summarize the
  intended outcome before reviewing.
- Compare the change with that intent and flag material scope creep or
  requirements the diff does not deliver.
- Read surrounding files and relevant references, not just the changed hunks.
  Check how scripts, manifests, Helm charts, Kustomize overlays, and Argo CD
  applications fit together.

## 2. Check evidence, not claims

- Inspect checks and workflow runs for the current PR head commit. Results from
  older commits do not establish that the current change passed.
- Distinguish verified evidence (such as rendered manifests, validation output,
  or successful CI) from claims in the PR description.
- Call out missing evidence explicitly: a check that was not run or whose
  output is unavailable is not a pass. Do not require production-cluster
  validation for a local kind-only change unless the change crosses that
  boundary.

## 3. Write high-confidence, actionable findings

- Report issues only when supported by the code or evidence. Prefer a small
  number of concrete findings to speculative concerns; phrase genuine
  uncertainty as a question.
- Anchor each finding to the narrowest relevant changed file and line. Explain
  impact and suggest a specific fix.
- Rank correctness, security, and unsafe cluster or deployment behavior above
  non-blocking concerns. Skip style-only nits unless requested.

## 4. Handle secrets and vulnerabilities safely

- If credentials, tokens, keys, connection strings, or sensitive
  tenant/subscription identifiers appear, identify the affected location
  without reproducing the value. Recommend removing it and rotating or
  revoking it as appropriate.
- Keep Kubernetes secrets out of plaintext manifests. Prefer supported
  secret references or clearly non-sensitive, local-only placeholders; do not
  mistake a placeholder for a usable secret.
- Describe vulnerabilities only at the level needed to fix them. Do not put
  exploit steps or sensitive details in public review comments; recommend
  private reporting when disclosure would expose a real system.

## 5. Require human approval for sensitive changes

- Do not approve a change on your own authority. Call out that the repository
  owner or another authorized human must explicitly review and approve changes
  affecting credentials, security controls, permissions, policy, cluster
  access, or deployment targets outside the disposable local kind lab.
- Treat changes that could reach a real AKS or other shared/production cluster
  as sensitive, even if the surrounding project is a local lab.
- Do not infer required reviewers or protected paths from governance files
  unless those files are present and their contents support that conclusion.

## 6. GitOps and lab-specific checks

### kind lifecycle

- Check cluster creation and teardown scripts are repeatable and safe to rerun.
- Confirm scripts use the intended kind cluster name and configuration, and
  avoid deleting or mutating unrelated clusters or resources.
- Ensure setup and cleanup instructions distinguish this disposable local lab
  from shared or production infrastructure.

### Argo CD, Helm, and Kubernetes manifests

- Treat Git as the declared source of truth. Flag routine manual
  `kubectl apply` workflows that bypass Argo CD reconciliation.
- Check whether automated sync, prune, and self-heal behavior is deliberate;
  scrutinize prune or deletion behavior for unintended impact.
- Verify Helm chart and dependency versions are pinned, and that relevant
  Helm templates, Kustomize overlays, or manifests render and validate when
  evidence is available.
- Check rendered resources target the intended kind cluster and namespace.
  Flag ambiguous or accidentally broad cluster/namespace targets.
- Check resource requests and limits, probes, and non-root security settings
  where relevant to the workload.

### GitHub Actions

- Check workflow and job permissions are least-privilege, defaulting to
  `contents: read`; require justification for write permissions.
- Pin third-party actions to full commit SHAs. Flag unsafe use of
  `pull_request_target`, untrusted checkout, or interpolation of untrusted
  input directly into shell commands.
- Ensure secrets are not exposed to fork pull requests or printed to logs.
- Check that CI validates the affected artifacts, for example by rendering
  Helm/Kustomize output or validating manifests when appropriate.

## 7. Summarize the review

Conclude with the stated intent, verified evidence, material missing checks,
findings by severity, and whether explicit human owner approval is required.
Recommend approve, request changes, or comment, with a brief reason. Never
self-approve or imply that a human approval requirement has been satisfied.
