{{/*
Expand the name of the chart.
*/}}
{{- define "mu2edaq-pager.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "mu2edaq-pager.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "mu2edaq-pager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for the proxy deployment/service pair.
*/}}
{{- define "mu2edaq-pager.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mu2edaq-pager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: proxy
{{- end }}
