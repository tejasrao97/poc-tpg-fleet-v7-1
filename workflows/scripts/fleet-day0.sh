#!/usr/bin/env bash
# fleet-day0.sh WORKFLOW_NAME CLUSTERS_JSON
# Write the tpg-day0 inputs into clusters/fleet.yaml for every selected cluster:
#   clusters.<cluster>.operator.version
#   clusters.<cluster>.instances.<instance>.instance.{postgresVersion, highAvailability, sizing}
#   clusters.<cluster>.instances.<instance>.backup.scheduled (backupSchedule=none)
# Existing entries keep their other settings. A different operator or Postgres version
# for something already declared fails: that is an upgrade (tpg-upgrade).
# dryRun=true: log the change and output it, push nothing. Otherwise commit with
# PUSH_MODE (direct | pr). Outputs /tmp/fleet.json: the planned fleet.yaml as JSON on a dry
# run (discover uses it instead of Git), otherwise {}.
# Inputs (environment): P_INSTANCES P_HA P_OPERATOR_VERSION P_POSTGRES_VERSION P_READ_REPLICAS
#   P_STORAGE_SIZE P_WAL_STORAGE_SIZE P_STORAGE_CLASS P_CPU P_MEMORY P_BACKUP_SCHEDULE P_DRY_RUN
WF="$1"; CLUSTERS_JSON="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"

REPO="$WORK/repo"
F="$REPO/clusters/fleet.yaml"
git_clone "$REPO"
cp "$F" "$WORK/fleet.before.yaml"
OPV="$(norm_operator_version "$P_OPERATOR_VERSION")"
PGV="$(norm_postgres_version "$P_POSTGRES_VERSION")"
HA="$P_HA"
RR="${P_READ_REPLICAS:-1}"; [[ "$HA" == "true" ]] || RR=0
FAILED=()

for c in $(jq -r '.[]' <<<"$CLUSTERS_JSON"); do
  max="$(fleet_cluster_value "$REPO" "$c" '.cluster.maxReadReplicas' 3)"
  if (( RR > max )); then
    FAILED+=("${c}: readReplicas ${RR} exceeds maxReadReplicas ${max}"); continue
  fi
  cur_opv="$(C="$c" yq -r '.clusters[strenv(C)].operator.version // ""' "$F")"
  if [[ -n "$cur_opv" && "$cur_opv" != "$OPV" ]]; then
    FAILED+=("${c}: operator ${cur_opv} is already declared; use tpg-upgrade component=operator to move to ${OPV}"); continue
  fi
  C="$c" V="$OPV" yq -i '.clusters[strenv(C)].operator.version = strenv(V)' "$F"
  for i in $(split_list "$P_INSTANCES"); do
    cur_pgv="$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].instance.postgresVersion // ""' "$F")"
    if [[ -n "$cur_pgv" && "$cur_pgv" != "$PGV" ]]; then
      FAILED+=("${c}/${i}: ${cur_pgv} is already declared; use tpg-upgrade component=postgres to move to ${PGV}"); continue
    fi
    C="$c" I="$i" V="$PGV" HA="$HA" RR="$RR" yq -i '
      .clusters[strenv(C)].instances[strenv(I)].instance.postgresVersion = strenv(V) |
      .clusters[strenv(C)].instances[strenv(I)].instance.highAvailability.enabled = (strenv(HA) == "true") |
      .clusters[strenv(C)].instances[strenv(I)].instance.highAvailability.readReplicas = (strenv(RR) | tonumber)' "$F"
    set_opt() {  # set_opt YQ_PATH VALUE (skipped when empty)
      [[ -n "$2" ]] || return 0
      C="$c" I="$i" X="$2" yq -i ".clusters[strenv(C)].instances[strenv(I)]$1 = strenv(X)" "$F"
    }
    set_opt .instance.storageSize "${P_STORAGE_SIZE:-}"
    set_opt .instance.walStorageSize "${P_WAL_STORAGE_SIZE:-}"
    set_opt .instance.storageClassName "${P_STORAGE_CLASS:-}"
    set_opt .instance.resources.data.requests.cpu "${P_CPU:-}"
    set_opt .instance.resources.data.limits.cpu "${P_CPU:-}"
    set_opt .instance.resources.data.requests.memory "${P_MEMORY:-}"
    set_opt .instance.resources.data.limits.memory "${P_MEMORY:-}"
    if [[ "${P_BACKUP_SCHEDULE:-fleet}" == "none" ]]; then
      C="$c" I="$i" yq -i '.clusters[strenv(C)].instances[strenv(I)].backup.scheduled = false' "$F"
    else
      C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].backup.scheduled) |
        del(.clusters[strenv(C)].instances[strenv(I)].backup | select(length == 0))' "$F"
    fi
  done
done

echo '{}' > /tmp/fleet.json
if [[ "${#FAILED[@]}" -gt 0 ]]; then
  record result.git FAILED FLEET_CONFLICT "$(printf '%s; ' "${FAILED[@]}")"
  exit 1
fi
changes="$(diff -u "$WORK/fleet.before.yaml" "$F" | tail -n +3 || true)"
if [[ -z "$changes" ]]; then
  record result.git SUCCEEDED NO_CHANGE "clusters/fleet.yaml already declares these inputs"
  exit 0
fi
log "clusters/fleet.yaml changes:"
printf '%s\n' "$changes" >&2
if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
  yq -o=json -I=0 '.' "$F" > /tmp/fleet.json
  record result.git SUCCEEDED DRY_RUN "$(grep -c '^[+-]' <<<"$changes") changed lines, not pushed"
  exit 0
fi
git_commit_push "$REPO" "day0: $(jq -r 'join(",")' <<<"$CLUSTERS_JSON") instances=${P_INSTANCES} ${PGV} ha=${HA} operator=${OPV} (${WF})" clusters/fleet.yaml \
  || { record result.git FAILED GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"; exit 1; }
appset_refresh tpg-operator
appset_refresh tpg-instances
record result.git SUCCEEDED "" "pushMode=${PUSH_MODE} $(cat /tmp/pull-request 2>/dev/null || true)"
