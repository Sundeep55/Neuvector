{{/* ---------------------------------------------------------------------- */}}
{{/* Naming                                                                  */}}
{{/* ---------------------------------------------------------------------- */}}
{{- define "dcs-neuvector.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "dcs-neuvector.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Target namespace. Declared explicitly as dcs.namespace to match how the other
NaaS components are configured, defaulting to the release namespace.

The upstream subchart hardcodes .Release.Namespace in its own templates, so the
two MUST agree — validate.yaml fails the render if they do not.
*/}}
{{- define "dcs-neuvector.namespace" -}}
{{- default .Release.Namespace .Values.dcs.namespace -}}
{{- end -}}

{{/*
Labels stamped on objects this wrapper owns.

Deliberately minimal. Not set here, because something else owns them:
  app.kubernetes.io/instance  -> ArgoCD's default instanceLabelKey; setting it
                                 ourselves can collide with app tracking
  app.kubernetes.io/managed-by -> only set by the Helm CLI; ArgoCD renders with
                                 `helm template`, so it would be inaccurate
*/}}
{{- define "dcs-neuvector.labels" -}}
app.kubernetes.io/name: {{ include "dcs-neuvector.name" . }}
app.kubernetes.io/part-of: neuvector
helm.sh/chart: {{ include "dcs-neuvector.chart" . }}
dcs.io/cluster-role: {{ .Values.dcs.role }}
{{- with .Values.dcs.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* ---------------------------------------------------------------------- */}}
{{/* sysinitcfg.yaml — declarative NeuVector system configuration.           */}}
{{/* ---------------------------------------------------------------------- */}}
{{- define "dcs-neuvector.sysinitcfg" -}}
{{- $s := .Values.dcs.systemConfig -}}
{{- $cfg := dict
      "always_reload"                 $s.alwaysReload
      "Cluster_Name"                  .Values.dcs.clusterName
      "New_Service_Policy_Mode"       $s.newServicePolicyMode
      "New_Service_Profile_Baseline"  $s.newServiceProfileBaseline
      "No_Telemetry_Report"           $s.noTelemetryReport
      "Monitor_Service_Mesh"          $s.monitorServiceMesh
      "Xff_Enabled"                   $s.xffEnabled
      "Unused_Group_Aging"            $s.unusedGroupAging
      "Allow_Ns_User_Export_Net_Policy" $s.allowNsUserExportNetPolicy
      "Mode_Auto_D2M"                 $s.modeAuto.discoverToMonitor
      "Mode_Auto_D2M_Duration"        $s.modeAuto.discoverToMonitorDuration
      "Mode_Auto_M2P"                 $s.modeAuto.monitorToProtect
      "Mode_Auto_M2P_Duration"        $s.modeAuto.monitorToProtectDuration
      "Scan_Config"                   (dict "Auto_Scan" $s.autoScan)
-}}
{{- if $s.scannerAutoscale.strategy -}}
{{- $_ := set $cfg "Scanner_Autoscale" (dict
      "Strategy" $s.scannerAutoscale.strategy
      "Min_Pods" $s.scannerAutoscale.minPods
      "Max_Pods" $s.scannerAutoscale.maxPods) -}}
{{- end -}}
{{- $cfg = mergeOverwrite $cfg (deepCopy ($s.extra | default dict)) -}}
{{- toYaml $cfg -}}
{{- end -}}
