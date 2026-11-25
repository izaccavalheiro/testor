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

{{- define "testor.scheme" -}}{{ if .Values.tls.existingSecret }}HTTPS{{ else }}HTTP{{ end }}{{- end -}}

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
