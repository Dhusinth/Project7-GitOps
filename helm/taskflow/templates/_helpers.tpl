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

{{/* Shared frontend container spec */}}
{{- define "taskflow.frontend.container" -}}
- name: frontend
  image: "{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag }}"
  imagePullPolicy: {{ .Values.frontend.image.pullPolicy }}
  ports:
    - name: http
      containerPort: {{ .Values.frontend.service.targetPort }}
  env:
    # Consumed by frontend/docker-entrypoint.sh to template nginx's `/api/`
    # reverse-proxy target. Must match the backend Service name + port
    # below (taskflow-backend / backend.service.port) — the image's own
    # default already matches this, but it's set explicitly here so the
    # chart is the source of truth, not an assumption baked into the image.
    - name: BACKEND_UPSTREAM
      value: "taskflow-backend:{{ .Values.backend.service.port }}"
  resources:
    {{- toYaml .Values.frontend.resources | nindent 4 }}
  livenessProbe:
    httpGet:
      path: /healthz
      port: http
    initialDelaySeconds: 5
    periodSeconds: 10
  readinessProbe:
    httpGet:
      path: /healthz
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

{{/* Shared backend container spec */}}
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
    - name: SECRET_KEY
      valueFrom:
        secretKeyRef:
          name: taskflow-secrets
          key: SECRET_KEY
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
