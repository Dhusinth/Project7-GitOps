{{/* Common name */}}
{{- define "taskflow.name" -}}
taskflow
{{- end }}

{{/* Common labels */}}
{{- define "taskflow.labels" -}}
app.kubernetes.io/part-of: taskflow
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* Backend selector labels */}}
{{- define "taskflow.backend.selectorLabels" -}}
app.kubernetes.io/name: taskflow-backend
app.kubernetes.io/component: backend
{{- end }}

{{/* Frontend selector labels */}}
{{- define "taskflow.frontend.selectorLabels" -}}
app.kubernetes.io/name: taskflow-frontend
app.kubernetes.io/component: frontend
{{- end }}

{{/* Postgres selector labels */}}
{{- define "taskflow.postgres.selectorLabels" -}}
app.kubernetes.io/name: taskflow-postgres
app.kubernetes.io/component: database
{{- end }}

{{/* Redis selector labels */}}
{{- define "taskflow.redis.selectorLabels" -}}
app.kubernetes.io/name: taskflow-redis
app.kubernetes.io/component: cache
{{- end }}

{{/* Shared frontend container spec, used by both Deployment and Argo Rollout */}}
{{- define "taskflow.frontend.container" -}}
- name: frontend
  image: "{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag }}"
  imagePullPolicy: {{ .Values.frontend.image.pullPolicy }}
  ports:
    - name: http
      containerPort: {{ .Values.frontend.service.targetPort }}
  resources:
    {{- toYaml .Values.frontend.resources | nindent 4 }}
  livenessProbe:
    httpGet:
      path: /
      port: http
    initialDelaySeconds: 5
    periodSeconds: 10
  readinessProbe:
    httpGet:
      path: /
      port: http
    initialDelaySeconds: 5
    periodSeconds: 10
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    capabilities:
      drop: ["ALL"]
{{- end }}

{{/* Shared backend container spec, used by both Deployment and Argo Rollout */}}
{{- define "taskflow.backend.container" -}}
- name: backend
  image: "{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag }}"
  imagePullPolicy: {{ .Values.backend.image.pullPolicy }}
  ports:
    - name: http
      containerPort: {{ .Values.backend.service.targetPort }}
  envFrom:
    - configMapRef:
        name: taskflow-backend-config
  env:
    - name: POSTGRES_PASSWORD
      valueFrom:
        secretKeyRef:
          name: taskflow-secrets
          key: POSTGRES_PASSWORD
    - name: SECRET_KEY
      valueFrom:
        secretKeyRef:
          name: taskflow-secrets
          key: SECRET_KEY
    - name: DATABASE_URL
      value: "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):5432/$(POSTGRES_DB)"
  resources:
    {{- toYaml .Values.backend.resources | nindent 4 }}
  livenessProbe:
    httpGet:
      path: {{ .Values.backend.probes.liveness.path }}
      port: http
    initialDelaySeconds: {{ .Values.backend.probes.liveness.initialDelaySeconds }}
    periodSeconds: {{ .Values.backend.probes.liveness.periodSeconds }}
  readinessProbe:
    httpGet:
      path: {{ .Values.backend.probes.readiness.path }}
      port: http
    initialDelaySeconds: {{ .Values.backend.probes.readiness.initialDelaySeconds }}
    periodSeconds: {{ .Values.backend.probes.readiness.periodSeconds }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    capabilities:
      drop: ["ALL"]
{{- end }}
