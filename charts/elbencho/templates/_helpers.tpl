{{/*
Expand the name of the chart.
*/}}
{{- define "elbencho.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "elbencho.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "elbencho.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "elbencho.labels" -}}
helm.sh/chart: {{ include "elbencho.chart" . }}
{{ include "elbencho.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "elbencho.selectorLabels" -}}
app.kubernetes.io/name: {{ include "elbencho.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Image reference
*/}}
{{- define "elbencho.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default (printf "v%s" .Chart.AppVersion) }}
{{- end }}

{{/*
Validate values and fail early with a clear message.
*/}}
{{- define "elbencho.validate" -}}
{{- if not (has .Values.mode (list "standalone" "service" "job")) }}
{{- fail (printf "mode must be one of standalone|service|job, got %q" .Values.mode) }}
{{- end }}
{{- if not (has .Values.protocol (list "file" "nfs" "block" "s3")) }}
{{- fail (printf "protocol must be one of file|nfs|block|s3, got %q" .Values.protocol) }}
{{- end }}
{{- if and (eq .Values.protocol "nfs") (not .Values.nfs.server) }}
{{- fail "protocol=nfs requires nfs.server" }}
{{- end }}
{{- if and (has .Values.protocol (list "file" "block")) .Values.persistence.enabled (not .Values.persistence.existingClaim) (not .Values.persistence.create) }}
{{- fail "persistence.enabled=true needs persistence.existingClaim or persistence.create=true" }}
{{- end }}
{{- if and (eq .Values.protocol "s3") .Values.s3.existingSecret (or .Values.s3.accessKey .Values.s3.secretKey) }}
{{- fail "set either s3.existingSecret or s3.accessKey/s3.secretKey, not both" }}
{{- end }}
{{- end }}

{{/*
Is a volume attached at all?
*/}}
{{- define "elbencho.hasStorage" -}}
{{- if eq .Values.protocol "nfs" }}true
{{- else if and (has .Values.protocol (list "file" "block")) .Values.persistence.enabled }}true
{{- end }}
{{- end }}

{{/*
Does each StatefulSet pod get its own PVC (volumeClaimTemplates)?
*/}}
{{- define "elbencho.perPodClaims" -}}
{{- if and (eq .Values.mode "service") (has .Values.protocol (list "file" "block")) .Values.persistence.enabled .Values.persistence.create (not .Values.persistence.existingClaim) (ne (toString .Values.persistence.perPod) "false") }}true{{- end }}
{{- end }}

{{/*
Name of the shared PVC used by the pods
*/}}
{{- define "elbencho.claimName" -}}
{{- if and (ne .Values.protocol "nfs") .Values.persistence.existingClaim -}}
{{ .Values.persistence.existingClaim }}
{{- else -}}
{{ include "elbencho.fullname" . }}
{{- end -}}
{{- end }}

{{/*
volumeMode for chart-created PVCs
*/}}
{{- define "elbencho.volumeMode" -}}
{{- if eq .Values.protocol "block" }}Block{{ else }}Filesystem{{ end }}
{{- end }}

{{/*
Name of the S3 credentials secret
*/}}
{{- define "elbencho.s3SecretName" -}}
{{- if .Values.s3.existingSecret }}{{ .Values.s3.existingSecret }}{{ else }}{{ include "elbencho.fullname" . }}-s3{{ end }}
{{- end }}

{{/*
Quote a list of args (elbencho args are often numbers)
*/}}
{{- define "elbencho.quoteList" -}}
{{- range . }}
- {{ toString . | quote }}
{{- end }}
{{- end }}

{{/*
Environment variables for the elbencho container
*/}}
{{- define "elbencho.env" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
{{- if eq .Values.protocol "s3" }}
{{- with .Values.s3.endpoints }}
- name: AWS_ENDPOINT_URL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.s3.region }}
- name: AWS_REGION
  value: {{ . | quote }}
{{- end }}
{{- if or .Values.s3.existingSecret .Values.s3.accessKey }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "elbencho.s3SecretName" . }}
      key: {{ .Values.s3.accessKeySecretKey }}
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "elbencho.s3SecretName" . }}
      key: {{ .Values.s3.secretKeySecretKey }}
{{- end }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Container fields shared by all modes: image, security, resources, env, storage.
*/}}
{{- define "elbencho.containerCommon" -}}
image: {{ include "elbencho.image" . | quote }}
imagePullPolicy: {{ .Values.image.pullPolicy }}
{{- with .Values.securityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.resources }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- $env := include "elbencho.env" . | trim }}
{{- if $env }}
env:
  {{- $env | nindent 2 }}
{{- end }}
{{- if include "elbencho.hasStorage" . }}
{{- if eq .Values.protocol "block" }}
volumeDevices:
  - name: {{ .Values.persistence.volumeName }}
    devicePath: {{ .Values.persistence.devicePath }}
{{- end }}
{{- end }}
{{- $mounts := list }}
{{- if and (include "elbencho.hasStorage" .) (ne .Values.protocol "block") }}
{{- $m := dict "name" .Values.persistence.volumeName "mountPath" .Values.persistence.mountPath }}
{{- if .Values.persistence.subPathPerPod }}{{ $_ := set $m "subPathExpr" "$(POD_NAME)" }}{{ end }}
{{- $mounts = append $mounts $m }}
{{- end }}
{{- $mounts = concat $mounts .Values.extraVolumeMounts }}
{{- with $mounts }}
volumeMounts:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Pod-level fields shared by all modes.
Pass a dict: (dict "ctx" $ "withClaim" true/false)
*/}}
{{- define "elbencho.podCommon" -}}
{{- $ := .ctx }}
{{- with $.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
terminationGracePeriodSeconds: {{ $.Values.terminationGracePeriodSeconds }}
{{- with $.Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- $vols := list }}
{{- if and .withClaim (include "elbencho.hasStorage" $) }}
{{- $vols = append $vols (dict "name" $.Values.persistence.volumeName "persistentVolumeClaim" (dict "claimName" (include "elbencho.claimName" $))) }}
{{- end }}
{{- $vols = concat $vols $.Values.extraVolumes }}
{{- with $vols }}
volumes:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $.Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $.Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $.Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Pod template metadata
*/}}
{{- define "elbencho.podMeta" -}}
labels:
  {{- include "elbencho.selectorLabels" . | nindent 2 }}
  {{- with .Values.podLabels }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- with .Values.podAnnotations }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Comma-separated list of service-mode daemon hosts
*/}}
{{- define "elbencho.hostList" -}}
{{- include "elbencho.hostListN" (dict "ctx" . "n" 0) }}
{{- end }}

{{/*
Host list for service instance n (0-based): port = service.port + n
*/}}
{{- define "elbencho.hostListN" -}}
{{- $ := .ctx }}
{{- $fn := include "elbencho.fullname" $ }}
{{- $port := add (int $.Values.service.port) (int .n) }}
{{- $hosts := list }}
{{- range $i := until (int $.Values.replicaCount) }}
{{- $hosts = append $hosts (printf "%s-%d.%s:%d" $fn $i $fn (int $port)) }}
{{- end }}
{{- join "," $hosts }}
{{- end }}

{{/*
Cluster-scoped NFS PV name (includes the namespace to avoid collisions)
*/}}
{{- define "elbencho.nfsPvName" -}}
{{- printf "%s-%s-nfs" .Release.Namespace (include "elbencho.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
S3 connection args prepended to job/coordinator runs. elbencho 3.1-5 does NOT pick up the endpoint
from AWS_ENDPOINT_URL in practice, so pass explicit flags. $(VAR) is expanded by Kubernetes from the
container env (values come from the Secret, so they never show up in the pod spec).
*/}}
{{- define "elbencho.s3Args" -}}
{{- if and (eq .Values.protocol "s3") (ne (toString .Values.s3.autoArgs) "false") }}
{{- if .Values.s3.endpoints }}
- "--s3endpoints"
- "$(AWS_ENDPOINT_URL)"
{{- end }}
{{- if .Values.s3.region }}
- "--s3region"
- "$(AWS_REGION)"
{{- end }}
{{- if or .Values.s3.existingSecret .Values.s3.accessKey }}
- "--s3key"
- "$(AWS_ACCESS_KEY_ID)"
- "--s3secret"
- "$(AWS_SECRET_ACCESS_KEY)"
{{- end }}
{{- end }}
{{- end }}
