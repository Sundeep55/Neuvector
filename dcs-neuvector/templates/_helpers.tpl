{{/* ---------------------------------------------------------------------- */}}
{{/* Naming                                                                  */}}
{{/* ---------------------------------------------------------------------- */}}
{{- define "dcs-neuvector.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "dcs-neuvector.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels stamped on every object this wrapper owns. */}}
{{- define "dcs-neuvector.labels" -}}
app.kubernetes.io/name: {{ include "dcs-neuvector.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: neuvector
helm.sh/chart: {{ include "dcs-neuvector.chart" . }}
dcs.io/cluster-role: {{ .Values.dcs.role }}
{{- with .Values.dcs.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "dcs-neuvector.annotations" -}}
{{- with .Values.dcs.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* ---------------------------------------------------------------------- */}}
{{/* Service accounts that need SCC access.                                  */}}
{{/* leastPrivilege=true creates one SA per component; otherwise everything   */}}
{{/* runs under core.serviceAccount.                                          */}}
{{/* ---------------------------------------------------------------------- */}}

{{/* SAs needing the privileged SCC (hostPID + privileged container). */}}
{{- define "dcs-neuvector.privilegedServiceAccounts" -}}
{{- if .Values.core.leastPrivilege -}}
enforcer
{{- else -}}
{{ .Values.core.serviceAccount }}
{{- end -}}
{{- end -}}

{{/* SAs needing anyuid (controller runs as uid 0; the rest want a stable UID). */}}
{{- define "dcs-neuvector.standardServiceAccounts" -}}
{{- if .Values.core.leastPrivilege -}}
{{- $sas := list "basic" "controller" "scanner" "updater" "cert-upgrader" -}}
{{- if .Values.core.cve.adapter.enabled -}}
{{- $sas = append $sas "registry-adapter" -}}
{{- end -}}
{{- join "," $sas -}}
{{- end -}}
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
