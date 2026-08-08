# Project 7 — Enterprise GitOps Release Platform

ArgoCD-driven GitOps repo answering: **can I safely release software into
production?** This repo holds only the desired-state manifests; the EKS
cluster, IAM, and VPC live in Terraform (project7-infra) and are out of
scope here.

## Architecture

```
Jenkins (Local)
      |
      v
   Docker
      |
      v
  Docker Hub
      |
      v
GitOps Repository (this repo)
      |
      v
ArgoCD ApplicationSet
      |
      v
    Helm
      |
      v
    EKS
   +--+--+
  dev   prod
```

TaskFlow is a **stateless** demo application:

- **Frontend** — React/Vite, served behind the ALB
- **Backend** — FastAPI, in-memory data store (no database)

There is no PostgreSQL, Redis, or any other persistent datastore. Every
TaskFlow workload is a plain Kubernetes `Deployment` — no StatefulSets, no
PVCs, no migration Jobs.

## Repo layout

```
bootstrap/        App-of-Apps root Application — the one thing you apply by hand
applications/     ArgoCD Application / ApplicationSet definitions (one per component)
helm/taskflow/    Helm chart for the TaskFlow demo app (frontend, backend)
```

## What gets deployed

`bootstrap/app-of-apps.yaml` points ArgoCD at the `applications/` folder.
Everything under it syncs automatically once the root app is applied:

| Application | Source | Deploys |
|---|---|---|
| `metrics-server` | metrics-server chart | Kubernetes Metrics Server (powers HPA) |
| `monitoring` | prometheus-community chart | kube-prometheus-stack (Prometheus, Grafana) |
| `taskflow` (ApplicationSet) | `helm/taskflow/` | TaskFlow app, one instance per environment (`dev`, `prod`) |

## Bootstrapping a cluster

Assumes: EKS cluster up, ArgoCD already installed in the `argocd` namespace.

```bash
kubectl apply -f bootstrap/app-of-apps.yaml
```

ArgoCD takes it from there — `syncPolicy.automated` with `prune: true` and
`selfHeal: true` means every Application above self-heals against this repo.

## Environments

`applications/taskflow-applicationset.yaml` uses an ArgoCD `ApplicationSet`
(a `list` generator) to create one ArgoCD Application per environment, each
pointed at `helm/taskflow/` with a different values file layered on top of
the shared `values.yaml` base:

- **dev** (`values-dev.yaml`) — 1 replica, HPA disabled, dev CORS origin, no ServiceMonitor.
- **prod** (`values-prod.yaml`) — 3+ replicas, HPA on CPU+memory, ServiceMonitor enabled. HTTP only via the ALB — no TLS/ACM cert, since this is a demo project without an owned domain.

The ApplicationSet generates two Applications: `taskflow-dev` and
`taskflow-prod`, deployed into the `dev` and `prod` namespaces respectively.

**Image tags are per-environment, not in the shared `values.yaml`.**
`backend.image` / `frontend.image` (repository + tag) are set independently
in `values-dev.yaml` and `values-prod.yaml`; `values.yaml`'s own `image`
block is just a fallback default for running `helm template` with no `-f`
flags at all — it's not the file a CI pipeline should be writing to.
Intended promotion flow: a Jenkins job (running locally) builds and pushes
images to Docker Hub, then updates the tag in `values-dev.yaml` and pushes
-> ArgoCD auto-syncs dev -> once verified, the same tag is copied into
`values-prod.yaml` as the deliberate gate before it reaches prod.

To add `staging` or `qa`, add another `elements` entry in
`taskflow-applicationset.yaml` and a matching `values-<env>.yaml`.

## Kubernetes resources

Each environment renders:

- `Deployment/taskflow-frontend`, `Deployment/taskflow-backend`
- `Service/taskflow-frontend`, `Service/taskflow-backend`
- `ConfigMap/taskflow-backend-config`
- `Secret/taskflow-secrets`
- `Ingress/taskflow-frontend-ingress`
- `HorizontalPodAutoscaler` for frontend and backend (when autoscaling is enabled)
- `ServiceMonitor/taskflow-backend` (when monitoring is enabled)

## Application routing

The backend's FastAPI routes are **unprefixed** (`/login`, `/tasks`,
`/me`, `/dashboard`, `/health`, `/live`, `/ready`, `/metrics` — no `/api`
prefix). The frontend calls `/api/...` (`API_BASE` in
`frontend/src/services/api.ts`), and the frontend's own nginx
(`frontend/nginx.conf.template`) reverse-proxies `location /api/` to the
backend Service, **stripping the `/api` prefix** before forwarding
(`proxy_pass http://__BACKEND_UPSTREAM__/;`, trailing slash strips the
match). `BACKEND_UPSTREAM` is set on the frontend container
(`taskflow-backend:<backend.service.port>`) so this always points at the
chart's own backend Service.

Only the **frontend** is exposed through the ALB/Ingress — the backend
Service is ClusterIP-only, reached in-cluster via the frontend's nginx
proxy (and by Prometheus for `/metrics`). Routing `/api/*` straight from
the ALB to the backend Service would send FastAPI a path it doesn't
serve (FastAPI has no `/api/login`, only `/login`), so there is
deliberately no backend Ingress.

```
Internet -> AWS ALB -> Ingress -> Frontend Service -> Frontend Pod (nginx)
                                                          |
                                          static assets   +-- /api/* --> Backend Service -> Backend Pod (FastAPI)
```

## Ingress / AWS ALB

Uses the AWS Load Balancer Controller (installed via Terraform, not this
repo) — no NGINX ingress controller. Each environment gets its own ALB
(one Ingress, targeting only the frontend Service). The ALB health check
(`alb.ingress.kubernetes.io/healthcheck-path`) targets `/healthz`, a
lightweight endpoint nginx serves directly — not the backend's `/health`,
which the ALB never reaches directly.

## HPA

Backend and frontend each have a CPU-based `HorizontalPodAutoscaler`
targeting their respective `Deployment` (`scaleTargetRef.kind: Deployment`).
No VPA, no Karpenter — this demo relies on existing EKS node capacity.

## Monitoring

Prometheus/Grafana come from the cluster-wide `monitoring` Application
(kube-prometheus-stack). The TaskFlow backend exposes `/metrics`, and
`helm/taskflow/templates/servicemonitor.yaml` (enabled per-environment via
`monitoring.serviceMonitor.enabled`) targets the backend Service so
Prometheus scrapes it automatically.

## Secrets

`helm/taskflow/templates/secret.yaml` renders a plain `Secret` from
`values.yaml`'s `secrets.secretKey`, committed with a placeholder value
only (`change-me-in-production`). Real environments should override this
out-of-band — Sealed Secrets, External Secrets Operator, or SOPS — never
by committing a real value into a `values-*.yaml` file.

## Local chart checks before pushing

```bash
helm lint helm/taskflow
helm template taskflow helm/taskflow -f helm/taskflow/values-dev.yaml
helm template taskflow helm/taskflow -f helm/taskflow/values-prod.yaml
```
