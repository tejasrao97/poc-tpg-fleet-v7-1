#!/usr/bin/env bash
# scale-instance.sh WORKFLOW_NAME CLUSTER INSTANCE REPLICAS TIMEOUT_SECONDS
# tpg-scale-instance: set the read replica count of one instance.
#   1 guards   instance declared in clusters/fleet.yaml and Running, 0 <= REPLICAS <= maxReadReplicas,
#              no upgrade or restore in progress
#   2 HA       REPLICAS > 0 needs highAvailability.enabled: turned on when P_ENABLE_HA=true,
#              otherwise the run fails. REPLICAS=0 keeps high availability as it is.
#   3 Git      clusters.<cluster>.instances.<instance>.instance.highAvailability in fleet.yaml
#              (PUSH_MODE direct | pr), then sync the instance Application and verify
# P_DRY_RUN=true records the plan and changes nothing.
WF="$1"; C="$2"; I="$3"; N="$4"; TIMEOUT="$5"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"

key="result.${C}.${I}"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"

[[ "$N" =~ ^[0-9]+$ ]] || fail OUT_OF_BOUNDS "replicas must be a non-negative integer"
REPO="$WORK/repo"
git_clone "$REPO"
fleet_has_cluster "$REPO" "$C" || fail UNKNOWN_CLUSTER "no clusters.${C} in ${FLEET_REL}"
fleet_has_instance "$REPO" "$C" "$I" || fail UNKNOWN_INSTANCE "declared instances on ${C}: $(fleet_instances "$REPO" "$C" | paste -sd,)"
max="$(fleet_cluster_value "$REPO" "$C" '.cluster.maxReadReplicas' 3)"
(( N <= max )) || fail OUT_OF_BOUNDS "replicas ${N} > maxReadReplicas ${max}"
ha="$(fleet_instance_value "$REPO" "$C" "$I" '.instance.highAvailability.enabled' true)"
cur="$(fleet_instance_value "$REPO" "$C" "$I" '.instance.highAvailability.readReplicas' 0)"
[[ "$ha" == "true" ]] || cur=0
HA="$ha"
if (( N > 0 )) && [[ "$ha" != "true" ]]; then
  [[ "${P_ENABLE_HA:-true}" == "true" ]] || fail HA_DISABLED "replicas ${N} needs highAvailability; set enableHAIfNeeded=true"
  HA=true
fi

use_cluster "$C" || fail NOT_REGISTERED
ns="pg-${I}"
[[ "$(pg_state "$I")" == "Running" ]] || fail NOT_RUNNING "currentState=$(pg_state "$I")"
for kind in postgresversionupgrade postgresrestore; do
  busy="$(tk -n "$ns" get "$kind" -o json 2>/dev/null \
    | jq -r '[.items[] | select((.status.phase // "") | test("^(Succeeded|Failed|PreCheckFailed)$") | not)] | length')"
  [[ "${busy:-0}" -eq 0 ]] || fail OPERATION_IN_PROGRESS "$kind"
done

if [[ "$cur" == "$N" && "$HA" == "$ha" ]]; then
  record "$key" SUCCEEDED ALREADY_AT_TARGET "readReplicas=${N}" "$cur"
  exit 0
fi
if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
  record "$key" SUCCEEDED DRY_RUN "would set readReplicas ${cur} -> ${N}, highAvailability ${ha} -> ${HA}" "$cur"
  exit 0
fi

C="$C" I="$I" N="$N" HA="$HA" yq -i '
  .clusters[strenv(C)].instances[strenv(I)].instance.highAvailability.enabled = (strenv(HA) == "true") |
  .clusters[strenv(C)].instances[strenv(I)].instance.highAvailability.readReplicas = (strenv(N) | tonumber)' "$REPO/$FLEET_REL"
git_commit_push "$REPO" "scale ${C}/${I} readReplicas ${cur} -> ${N} (${WF})" "$FLEET_REL" || fail GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"

app="tpg-${C}-${I}"
app_refresh "$app"
app_sync "$app" || fail SYNC_REQUEST_FAILED "$app"
app_wait "$app" 900 || fail SYNC_FAILED "$app"

sleep 30  # give the operator time to observe the spec change
spec_rr="$(tk -n "$ns" get postgres "$I" -o jsonpath='{.spec.highAvailability.readReplicas}')"
[[ "${spec_rr:-0}" == "$N" ]] || fail SPEC_NOT_APPLIED "spec.highAvailability.readReplicas=${spec_rr}"
pg_wait_running "$I" "$TIMEOUT" || fail NOT_RUNNING_AFTER_SCALE
sts_wait_ready "$I" "$TIMEOUT" || fail REPLICAS_NOT_READY
ready="$(tk -n "$ns" get statefulset "$I" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
record "$key" SUCCEEDED "" "readReplicas=${N}, highAvailability=${HA}, statefulset ready ${ready}" "$cur"
