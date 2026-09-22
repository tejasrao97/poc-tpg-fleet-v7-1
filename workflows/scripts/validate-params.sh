#!/usr/bin/env bash
# validate-params.sh MODE
# Validates workflow input parameters before anything changes. Parameters come
# from P_* environment variables set by the WorkflowTemplate. Mandatory inputs
# have no default: an empty value fails with the list of valid choices.
# Outputs /tmp/clusters.json (normalized cluster list) for withParam loops.
MODE="$1"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

ERRORS=()
err() { ERRORS+=("$*"); }
REGISTERED="$(registered_clusters)"
REG_LIST="$(paste -sd, <<<"$REGISTERED")"

need() {        # need NAME VALUE HINT
  [[ -n "$2" ]] || err "$1 is mandatory: $3"
}
bool() {        # bool NAME VALUE
  [[ "$2" == "true" || "$2" == "false" ]] || err "$1 must be true or false (got '${2}')"
}
oneof() {       # oneof NAME VALUE CHOICE...
  local n="$1" v="$2" c; shift 2
  for c in "$@"; do [[ "$v" == "$c" ]] && return 0; done
  err "$n must be one of: $* (got '${v}')"
}
posint() {      # posint NAME VALUE
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || err "$1 must be a positive integer (got '${2}')"
}
nonneg() {
  [[ "$2" =~ ^[0-9]+$ ]] || err "$1 must be a non-negative integer (got '${2}')"
}
quantity() {    # quantity NAME VALUE (empty allowed)
  [[ -z "$2" || "$2" =~ ^[0-9]+(\.[0-9]+)?(m|Ki|Mi|Gi|Ti|k|M|G|T)?$ ]] || err "$1 must be a Kubernetes quantity such as 20Gi or 500m (got '${2}')"
}
dnsname() {     # dnsname NAME VALUE
  [[ "$2" =~ ^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$ ]] || err "$1 '${2}' must be a lowercase DNS label (letters, digits, '-', at most 40 characters)"
}
clusters_in() {  # clusters_in NAME VALUE ALLOW_ALL -> validates and writes /tmp/clusters.json
  local n="$1" v="$2" allow_all="$3" c out="[]"
  if [[ -z "$v" ]]; then
    err "$n is mandatory: comma-separated cluster names${allow_all:+ or all}. Registered clusters: ${REG_LIST:-none}"
    return
  fi
  if [[ "$v" == "all" ]]; then
    if [[ -z "$allow_all" ]]; then err "$n does not accept all: list the clusters. Registered clusters: ${REG_LIST:-none}"; return; fi
    printf '%s' "$(jq -cn --arg r "$REGISTERED" '$r | split("\n") | map(select(length > 0))')" > /tmp/clusters.json
    return
  fi
  for c in $(split_list "$v"); do
    grep -qx "$c" <<<"$REGISTERED" || err "$n: cluster '${c}' is not registered. Registered clusters: ${REG_LIST:-none}"
    out="$(jq -c --arg c "$c" 'if index($c) then . else . + [$c] end' <<<"$out")"
  done
  printf '%s' "$out" > /tmp/clusters.json
}
instances_in() { # instances_in NAME VALUE ALLOW_ALL
  local i
  if [[ -z "$2" ]]; then err "$1 is mandatory: comma-separated instance names${3:+ or all}"; return; fi
  [[ "$2" == "all" && -n "$3" ]] && return
  for i in $(split_list "$2"); do dnsname "$1" "$i"; done
}
opver() { [[ "$2" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$ ]] || err "$1 must be an operator chart version such as v4.5.0 (got '${2}')"; }
pgver() { [[ "$2" =~ ^(postgres-)?[0-9]+(\.[0-9]+)?$ ]] || err "$1 must be a Postgres version such as postgres-17.6 or 17.6 (got '${2}')"; }

echo '[]' > /tmp/clusters.json
case "$MODE" in
  day0)
    clusters_in clusters "${P_CLUSTERS:-}" allow
    instances_in instances "${P_INSTANCES:-}"
    need highAvailability "${P_HA:-}" "true or false"; [[ -z "${P_HA:-}" ]] || bool highAvailability "$P_HA"
    need operatorVersion "${P_OPERATOR_VERSION:-}" "for example v4.5.0"; [[ -z "${P_OPERATOR_VERSION:-}" ]] || opver operatorVersion "$P_OPERATOR_VERSION"
    need postgresVersion "${P_POSTGRES_VERSION:-}" "for example postgres-17.6"; [[ -z "${P_POSTGRES_VERSION:-}" ]] || pgver postgresVersion "$P_POSTGRES_VERSION"
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    nonneg readReplicas "${P_READ_REPLICAS:-1}"
    quantity storageSize "${P_STORAGE_SIZE:-}"; quantity walStorageSize "${P_WAL_STORAGE_SIZE:-}"
    quantity cpu "${P_CPU:-}"; quantity memory "${P_MEMORY:-}"
    [[ -z "${P_STORAGE_CLASS:-}" ]] || dnsname storageClass "$P_STORAGE_CLASS"
    oneof backupSchedule "${P_BACKUP_SCHEDULE:-fleet}" fleet none
    oneof monitoringOption "${P_MONITORING_OPTION:-}" "" none azure standalone
    bool installAddons "${P_INSTALL_ADDONS:-true}"; bool dryRun "${P_DRY_RUN:-false}"
    oneof existingAddons "${P_EXISTING:-skip}" skip upgrade
    posint maxParallel "${P_MAX_PARALLEL:-2}"; posint syncTimeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  upgrade)
    need component "${P_COMPONENT:-}" "operator or postgres"; [[ -z "${P_COMPONENT:-}" ]] || oneof component "$P_COMPONENT" operator postgres
    need targetVersion "${P_TARGET_VERSION:-}" "operator: v4.5.0; postgres: postgres-17.6"
    if [[ -n "${P_TARGET_VERSION:-}" ]]; then
      case "${P_COMPONENT:-}" in
        operator) opver targetVersion "$P_TARGET_VERSION" ;;
        postgres) pgver targetVersion "$P_TARGET_VERSION" ;;
      esac
    fi
    clusters_in clusters "${P_CLUSTERS:-}" allow
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    if [[ "${P_COMPONENT:-}" == "postgres" ]]; then
      instances_in instances "${P_INSTANCES:-}" allow
    elif [[ -n "${P_INSTANCES:-}" ]]; then
      err "instances applies only to component=postgres (the operator is upgraded for the whole cluster)"
    fi
    bool preUpgradeBackup "${P_PRE_BACKUP:-true}"; bool allowMajor "${P_ALLOW_MAJOR:-false}"; bool dryRun "${P_DRY_RUN:-false}"
    posint maxParallel "${P_MAX_PARALLEL:-1}"; posint timeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  scale)
    need cluster "${P_CLUSTER:-}" "one cluster name. Registered clusters: ${REG_LIST:-none}"
    if [[ -n "${P_CLUSTER:-}" ]]; then
      [[ "$P_CLUSTER" != *,* ]] || err "cluster takes one cluster name"
      clusters_in cluster "$P_CLUSTER" ""
    fi
    need instance "${P_INSTANCE:-}" "the Postgres instance name"; [[ -z "${P_INSTANCE:-}" ]] || dnsname instance "$P_INSTANCE"
    need replicas "${P_REPLICAS:-}" "number of read replicas (0 to maxReadReplicas)"; [[ -z "${P_REPLICAS:-}" ]] || nonneg replicas "$P_REPLICAS"
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    bool enableHAIfNeeded "${P_ENABLE_HA:-true}"; bool dryRun "${P_DRY_RUN:-false}"
    posint timeoutSeconds "${P_TIMEOUT:-900}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  restore)
    need sourceCluster "${P_SOURCE_CLUSTER:-}" "one registered cluster. Registered clusters: ${REG_LIST:-none}"
    [[ -z "${P_SOURCE_CLUSTER:-}" ]] || clusters_in sourceCluster "$P_SOURCE_CLUSTER" ""
    need instance "${P_INSTANCE:-}" "the Postgres instance to restore from"; [[ -z "${P_INSTANCE:-}" ]] || dnsname instance "$P_INSTANCE"
    need mode "${P_MODE:-}" "time, latest, backup, lsn or xid"
    [[ -z "${P_MODE:-}" ]] || oneof mode "$P_MODE" time latest backup lsn xid
    case "${P_MODE:-}" in
      time)
        need targetTime "${P_TARGET_TIME:-}" "UTC timestamp such as 2026-09-01T10:30:00Z"
        [[ -z "${P_TARGET_TIME:-}" || "$P_TARGET_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
          || err "targetTime must look like 2026-09-01T10:30:00Z" ;;
      backup) need backupName "${P_BACKUP_NAME:-}" "a PostgresBackup name in the source namespace" ;;
      lsn) need lsn "${P_LSN:-}" "a log sequence number" ;;
      xid) need xid "${P_XID:-}" "a transaction ID"; [[ -z "${P_XID:-}" ]] || nonneg xid "$P_XID" ;;
    esac
    # Exactly one recovery point for the chosen mode
    given=""
    [[ -z "${P_TARGET_TIME:-}" ]] || given="${given}targetTime "
    [[ -z "${P_BACKUP_NAME:-}" ]] || given="${given}backupName "
    [[ -z "${P_LSN:-}" ]] || given="${given}lsn "
    [[ -z "${P_XID:-}" ]] || given="${given}xid "
    case "$(printf '%s' "$given" | wc -w)" in
      0|1) ;;  # 0 is already reported by the per-mode need above (mode=latest takes none)
      *) err "set only the recovery point of the chosen mode (given: ${given})" ;;
    esac
    [[ "${P_MODE:-}" != "latest" || -z "$given" ]] || err "mode=latest takes no recovery point (given: ${given})"
    if [[ -n "${P_TARGET_CLUSTER:-}" ]]; then
      clusters_in targetCluster "$P_TARGET_CLUSTER" ""
      [[ "${P_MODE:-}" != "backup" || "$P_TARGET_CLUSTER" == "${P_SOURCE_CLUSTER:-}" ]] \
        || err "mode=backup restores only inside the source namespace; use time, latest, lsn or xid for another cluster"
    fi
    [[ -z "${P_TARGET_INSTANCE:-}" ]] || dnsname targetInstance "$P_TARGET_INSTANCE"
    if [[ -n "${P_TARGET_INSTANCE:-}" && "${P_TARGET_INSTANCE}" != "${P_INSTANCE:-}" && "${P_MODE:-}" == "backup" ]]; then
      err "mode=backup restores only inside the source namespace (target namespace pg-${P_TARGET_INSTANCE}); use time, latest, lsn or xid"
    fi
    if [[ "${P_TARGET_INSTANCE:-}" == "${P_INSTANCE:-}" && -n "${P_INSTANCE:-}" ]]; then
      [[ "${P_CONFIRM:-}" == "${P_INSTANCE}" ]] || err "an in-place restore overwrites ${P_INSTANCE}: set confirm=${P_INSTANCE}"
    fi
    oneof pushMode "${P_PUSH_MODE:-direct}" direct pr
    bool bestEffort "${P_BEST_EFFORT:-false}"
    posint restoreTimeoutSeconds "${P_TIMEOUT:-7200}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  delete-instance)
    need cluster "${P_CLUSTER:-}" "one cluster name. Registered clusters: ${REG_LIST:-none}"
    [[ -z "${P_CLUSTER:-}" ]] || clusters_in cluster "$P_CLUSTER" ""
    need instance "${P_INSTANCE:-}" "the Postgres instance to delete"; [[ -z "${P_INSTANCE:-}" ]] || dnsname instance "$P_INSTANCE"
    oneof pushMode "${P_PUSH_MODE:-direct}" direct pr
    ;;
  delete-apps)
    clusters_in clusters "${P_CLUSTERS:-}" ""
    need apps "${P_APPS:-}" 'JSON map, for example {"aks-tpg-poc-01":["tpg-instances:orders-db","tpg-operator"]}'
    if [[ -n "${P_APPS:-}" ]]; then
      if ! jq -e 'type == "object"' <<<"$P_APPS" >/dev/null 2>&1; then
        err "apps must be a JSON object that maps each cluster to a list of applications"
      else
        for c in $(jq -r '.[]' /tmp/clusters.json); do
          jq -e --arg c "$c" 'has($c) and (.[$c] | type == "array" and length > 0)' <<<"$P_APPS" >/dev/null \
            || err "apps has no application list for cluster ${c}"
        done
        for c in $(jq -r 'keys[]' <<<"$P_APPS"); do
          jq -e --arg c "$c" 'index($c)' /tmp/clusters.json >/dev/null || err "apps lists cluster ${c}, which is not in clusters"
        done
        while read -r a; do
          [[ -z "$a" ]] && continue
          case "$a" in
            tpg-operator|tpg-instances|tpg-instances:all) ;;
            tpg-instances:*) for i in $(split_list "${a#tpg-instances:}"); do dnsname "apps instance" "$i"; done ;;
            *) err "apps: unknown application '${a}'; use tpg-instances, tpg-instances:<instance>[,<instance>] or tpg-operator" ;;
          esac
        done < <(jq -r '.[] | .[]? | tostring' <<<"$P_APPS")
      fi
    fi
    need confirm "${P_CONFIRM:-}" "repeat the clusters value exactly"
    if [[ -n "${P_CONFIRM:-}" ]]; then
      [[ "$(split_list "$P_CONFIRM" | paste -sd,)" == "$(split_list "${P_CLUSTERS:-}" | paste -sd,)" ]] \
        || err "confirm must repeat the clusters value (${P_CLUSTERS:-})"
    fi
    need dryRun "${P_DRY_RUN:-}" "true (plan only) or false"; [[ -z "${P_DRY_RUN:-}" ]] || bool dryRun "$P_DRY_RUN"
    need purgePvcs "${P_PURGE_PVCS:-}" "true deletes PVCs and Azure disks, false keeps them"; [[ -z "${P_PURGE_PVCS:-}" ]] || bool purgePvcs "$P_PURGE_PVCS"
    need purgeNamespace "${P_PURGE_NS:-}" "true deletes the pg-<instance> namespaces, false keeps them"; [[ -z "${P_PURGE_NS:-}" ]] || bool purgeNamespace "$P_PURGE_NS"
    [[ "${P_PURGE_NS:-}" != "true" || "${P_PURGE_PVCS:-}" == "true" ]] || err "purgeNamespace=true needs purgePvcs=true"
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    bool force "${P_FORCE:-false}"; oneof finalBackup "${P_FINAL_BACKUP:-true}" true false required
    posint timeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  helm-addons)
    clusters_in clusters "${P_CLUSTERS:-}" allow
    for comp in $(split_list "${P_COMPONENTS:-auto}"); do oneof components "$comp" auto cert-manager vso monitoring; done
    [[ "${P_COMPONENTS:-auto}" != *auto* || "${P_COMPONENTS:-auto}" == "auto" ]] || err "components: auto cannot be combined with other components"
    bool dryRun "${P_DRY_RUN:-false}"
    oneof existingAddons "${P_EXISTING:-skip}" skip upgrade
    ;;
  backup-retention)
    clusters_in clusters "${P_CLUSTERS:-all}" allow
    [[ -z "${P_RETENTION_DAYS:-}" ]] || posint retentionDays "$P_RETENTION_DAYS"
    bool dryRun "${P_DRY_RUN:-false}"
    ;;
  *) err "unknown validation mode ${MODE}" ;;
esac

if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  echo "Invalid input parameters:" >&2
  printf '  - %s\n' "${ERRORS[@]}" >&2
  exit 1
fi
[[ "$(jq 'length' /tmp/clusters.json)" -gt 0 || "$MODE" == "scale" || "$MODE" == "delete-instance" ]] \
  || { echo "no registered clusters selected (registered: ${REG_LIST:-none})" >&2; exit 1; }
log "parameters valid (${MODE}); clusters $(cat /tmp/clusters.json)"
