# Project 7 — Release Engineering Platform (GitOps)

ArgoCD-driven GitOps repo answering: **can I safely release software into
production?** This repo holds only the desired-state manifests; the EKS
cluster, IAM, VPC, and the Karpenter *controller* itself live in Terraform
(project7-infra) and are out of scope here.

## Repo layout

```
bootstrap/        App-of-Apps root Application — the one thing you apply by hand
applications/     ArgoCD Application / ApplicationSet definitions (one per component)
helm/taskflow/    Helm chart for the TaskFlow demo app (frontend, backend, Postgres, Redis)
karpenter/        EC2NodeClass / NodePool custom resources (Karpenter controller installed via Terraform, not here)
```

## What gets deployed

`bootstrap/app-of-apps.yaml` points ArgoCD at the `applications/` folder.
Everything under it syncs automatically once the root app is applied:

| Application | Source | Deploys |
|---|---|---|
| `argo-rollouts` | argo-helm chart | Argo Rollouts controller |
| `monitoring` | prometheus-community chart | kube-prometheus-stack (Prometheus, Grafana, Loki) |
| `karpenter` | `karpenter/` (this repo) | EC2NodeClass + NodePool only — the Karpenter controller is installed by Terraform |
| `taskflow` (ApplicationSet) | `helm/taskflow/` | TaskFlow app, one instance per environment (`dev`, `prod`) |

## Bootstrapping a cluster

Assumes: EKS cluster up, ArgoCD already installed in the `argocd` namespace,
Karpenter controller already installed via Terraform.

```bash
kubectl apply -f bootstrap/app-of-apps.yaml
```

ArgoCD takes it from there — `syncPolicy.automated` with `prune: true` and
`selfHeal: true` means every Application above self-heals against this repo.

## Environments

`applications/taskflow-applicationset.yaml` generates one ArgoCD Application
per environment, each pointed at `helm/taskflow/` with a different values
file merged on top of the shared `values.yaml` base:

- **dev** (`values-dev.yaml`) — 1 replica, no TLS, auto-sync, demo data seeded on every deploy.
- **prod** (`values-prod.yaml`) — 3+ replicas, canary rollout gated by a Prometheus success-rate `AnalysisTemplate`, HPA on CPU+memory. HTTP only via the ALB — no TLS/ACM cert, since this is a demo project without an owned domain.

Both are always deployed as Argo Rollouts, not plain Deployments — see
[Progressive delivery](#progressive-delivery) below.

**Image tags are per-environment, not in the shared `values.yaml`.**
`backend.image` / `frontend.image` (repository + tag) are set independently
in `values-dev.yaml` and `values-prod.yaml`; `values.yaml`'s own `image`
block is just a fallback default for running `helm template` with no `-f`
flags at all — it's not the file a CI pipeline should be writing to.
Intended promotion flow: a Jenkins job updates the tag in
`values-dev.yaml` and pushes → ArgoCD auto-syncs dev → once verified, the
same tag is copied into `values-prod.yaml` (manually today; script/CI-driven
later) as the deliberate gate before it reaches prod.

To add `staging` or `qa`, add another `elements` entry in
`taskflow-applicationset.yaml` and a matching `values-<env>.yaml`.

## Progressive delivery

Both backend and frontend deploy as Argo Rollouts (not plain Deployments)
in every environment — Argo Rollouts is installed cluster-wide via
`applications/argo-rollouts.yaml`, so there's no fallback path to
maintain. `backend.rolloutStrategy` / `frontend.rolloutStrategy` pick
`canary` (default) or `blueGreen` independently for each.

`taskflow-frontend-ingress` and `taskflow-backend-ingress` share a single
ALB (via the `alb.ingress.kubernetes.io/group.name: taskflow` annotation —
the AWS Load Balancer Controller is installed by Terraform, not this
repo). The canary strategy ramps traffic in steps (10% → 25% → 50% →
100%) using Argo Rollouts' native `trafficRouting.alb` integration, which
manages weighted target groups on that ALB directly — no ingress
controller sidecar or extra CRDs needed. The backend canary additionally
pauses at each step to run an automated Prometheus success-rate check
(`analysis-template.yaml`) before continuing; a failed check halts the
rollout and it can be aborted/rolled back with `kubectl argo rollouts undo
taskflow-backend -n taskflow`.

## Secrets

`helm/taskflow/templates/secret.yaml` renders a plain `Secret` from
`values.yaml`'s `secrets.*` block, which is committed with placeholder
values only (`change-me-in-production`). Real environments should override
these out-of-band — Sealed Secrets, External Secrets Operator, or SOPS —
never by committing real values into a `values-*.yaml` file.

## Local chart checks before pushing

```bash
helm lint helm/taskflow
helm template helm/taskflow -f helm/taskflow/values-dev.yaml
helm template helm/taskflow -f helm/taskflow/values-prod.yaml
```
