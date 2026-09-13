{{/* O nome da release é o nome do serviço: vira nome do Deployment, do Service
     (DNS interno) e do ServiceAccount usado pela role IRSA. */}}
{{- define "fiapx-service.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fiapx-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fiapx-service.name" . }}
{{- end -}}

{{- define "fiapx-service.labels" -}}
{{ include "fiapx-service.selectorLabels" . }}
app.kubernetes.io/part-of: fiapx
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
