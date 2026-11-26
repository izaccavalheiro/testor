{{- define "testor.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{- else -}}{{ printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- end -}}

{{- define "testor.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "testor.selector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "testor.image" -}}
{{- if .Values.image.digest -}}{{ .Values.image.repository }}@{{ .Values.image.digest }}{{- else -}}{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}{{- end -}}
{{- end -}}

{{- define "testor.allowedHosts" -}}
{{- $name := include "testor.fullname" . -}}
{{- $hosts := list $name (printf "%s.%s" $name .Release.Namespace) (printf "%s.%s.svc" $name .Release.Namespace) (printf "%s.%s.svc.cluster.local" $name .Release.Namespace) -}}
{{- if .Values.ingress.enabled }}{{ $hosts = append $hosts .Values.ingress.host }}{{ end -}}
{{- join "," (concat $hosts .Values.allowedHosts) -}}
{{- end -}}

{{/*
config.json as the chart renders it: .Values.config, with storage.s3 as its "storage".
*/}}
{{- define "testor.config" -}}
{{- $config := deepCopy .Values.config -}}
{{- $s3 := .Values.storage.s3 -}}
{{- if $s3.bucket -}}
{{- if not $s3.region }}{{ fail "storage.s3.region: the bucket's region" }}{{ end -}}
{{- $storage := dict "type" "s3" "bucket" $s3.bucket "region" $s3.region "pathStyle" $s3.pathStyle "presign" $s3.presign "cacheMB" (int $s3.cacheMB) -}}
{{- range $key := list "endpoint" "prefix" "publicEndpoint" "encryption" "kmsKeyId" -}}
{{- with index $s3 $key }}{{ $_ := set $storage $key . }}{{ end -}}
{{- end -}}
{{- $_ := set $config "storage" $storage -}}
{{- end -}}
{{- toPrettyJson $config -}}
{{- end -}}

{{- define "testor.scheme" -}}{{ if or .Values.tls.existingSecret .Values.tls.acme }}HTTPS{{ else }}HTTP{{ end }}{{- end -}}

{{- define "testor.agentSelector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}-agent
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "testor.agentImage" -}}
{{- $a := .Values.agents.image -}}
{{- if $a.digest -}}{{ $a.repository }}@{{ $a.digest }}{{- else -}}{{ $a.repository }}:{{ $a.tag | default .Chart.AppVersion }}{{- end -}}
{{- end -}}

{{- define "testor.agentServer" -}}
{{- if .Values.agents.server -}}{{ .Values.agents.server }}{{- else -}}{{ include "testor.scheme" . | lower }}://{{ include "testor.fullname" . }}.{{ .Release.Namespace }}.svc:{{ .Values.service.port }}{{- end -}}
{{- end -}}

{{- define "testor.agentServiceAccount" -}}
{{- if .Values.agents.serviceAccount.create }}{{ include "testor.fullname" . }}-agent{{ else }}{{ .Values.agents.serviceAccount.name }}{{ end -}}
{{- end -}}

{{/*
The agents to deploy, as a JSON list: the default group (agents.*), then each of
agents.profiles. Each has a name suffix, labels, resources, replicas, autoscaling, mode
(deployment or job), shmSize, workspaceSizeLimit and the label its KEDA query counts.
*/}}
{{- define "testor.agentGroups" -}}
{{- $a := .Values.agents -}}
{{- $groups := list -}}
{{- if $a.enabled -}}
{{- $groups = append $groups (dict "suffix" "" "labels" $a.labels "resources" $a.resources "replicas" $a.replicas "autoscaling" $a.autoscaling "mode" "deployment" "shmSize" "" "workspaceSizeLimit" "" "scaleLabel" "") -}}
{{- range $p := $a.profiles -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$" (toString $p.name)) }}{{ fail "agents.profiles[].name: a DNS label of 32 characters at most" }}{{ end -}}
{{- if not $p.labels }}{{ fail (printf "agents.profiles %s: labels, which its jobs ask for" $p.name) }}{{ end -}}
{{- $mode := $p.mode | default "deployment" -}}
{{- if not (has $mode (list "deployment" "job")) }}{{ fail (printf "agents.profiles %s: mode is deployment or job" $p.name) }}{{ end -}}
{{- $auto := merge (dict) ($p.autoscaling | default dict) (dict "keda" (eq $mode "job") "minReplicas" 0 "maxReplicas" 5 "queuedPerAgent" 1) -}}
{{- $_ := set $auto "prometheusServer" ($auto.prometheusServer | default $a.autoscaling.prometheusServer) -}}
{{- $groups = append $groups (dict "suffix" (printf "-%s" $p.name) "labels" $p.labels "resources" ($p.resources | default $a.resources) "replicas" ($p.replicas | default 1) "autoscaling" $auto "mode" $mode "shmSize" ($p.shmSize | default "") "workspaceSizeLimit" ($p.workspaceSizeLimit | default "") "scaleLabel" ($auto.label | default (last $p.labels))) -}}
{{- end -}}
{{- end -}}
{{- toJson $groups -}}
{{- end -}}

{{/* The pods of an agent profile: a name of their own, so no two Deployments select the same pods. */}}
{{- define "testor.agentProfileSelector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}-agent-profile
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* The selector of a group's pods: the default agents', or a profile's. */}}
{{- define "testor.agentGroupSelector" -}}
{{- if .group.suffix -}}
{{ include "testor.agentProfileSelector" .root }}
testor.dev/profile: {{ .group.suffix | trimPrefix "-" | quote }}
{{- else -}}
{{ include "testor.agentSelector" .root }}
{{- end -}}
{{- end -}}

{{/* An agent's pod spec: `root` (the chart's context) and `group` (one of testor.agentGroups). */}}
{{- define "testor.agentPodSpec" -}}
{{- $ := .root -}}
{{- $g := .group -}}
{{- with (include "testor.agentServiceAccount" $) }}
serviceAccountName: {{ . }}
{{- end }}
automountServiceAccountToken: {{ $.Values.agents.serviceAccount.automountToken }}
# No Kubernetes service links: a Service named testor would set TESTOR_PORT and the like.
enableServiceLinks: false
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  fsGroup: 10001
  seccompProfile: { type: RuntimeDefault }
# A job in progress gets time to end and be sent before the pod goes.
terminationGracePeriodSeconds: 120
{{- if eq $g.mode "job" }}
restartPolicy: Never
{{- end }}
containers:
  - name: agent
    image: {{ include "testor.agentImage" $ }}
    imagePullPolicy: {{ $.Values.agents.image.pullPolicy }}
    {{- if eq $g.mode "job" }}
    # A Job per run: take one job, run it, exit.
    args: ["-Once"]
    {{- end }}
    env:
      - name: TESTOR_AGENT_TOKEN
        valueFrom: { secretKeyRef: { name: {{ $.Values.agents.tokenSecret }}, key: token } }
      {{- with $.Values.agents.env }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: [ALL] }
    resources: {{- toYaml $g.resources | nindent 6 }}
    volumeMounts:
      - { name: config, mountPath: /etc/testor-agent, readOnly: true }
      - { name: home, mountPath: /home/agent }
      - { name: tmp, mountPath: /tmp }
      {{- if $g.shmSize }}
      - { name: shm, mountPath: /dev/shm }
      {{- end }}
      {{- range $i, $mount := $.Values.agents.secretMounts }}
      - { name: secret-{{ $i }}, mountPath: {{ $mount.mountPath }}, readOnly: true }
      {{- end }}
volumes:
  - name: config
    configMap: { name: {{ include "testor.fullname" $ }}-agent{{ $g.suffix }} }
  - name: home
    emptyDir: {{ if $g.workspaceSizeLimit }}{ sizeLimit: {{ $g.workspaceSizeLimit }} }{{ else }}{}{{ end }}
  - name: tmp
    emptyDir: {}
  {{- if $g.shmSize }}
  # Browsers need more shared memory than the default 64 MB.
  - name: shm
    emptyDir: { medium: Memory, sizeLimit: {{ $g.shmSize }} }
  {{- end }}
  {{- range $i, $mount := $.Values.agents.secretMounts }}
  - name: secret-{{ $i }}
    secret: { secretName: {{ $mount.secret }}, defaultMode: 0440 }
  {{- end }}
{{- with $.Values.nodeSelector }}
nodeSelector: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $.Values.tolerations }}
tolerations: {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
