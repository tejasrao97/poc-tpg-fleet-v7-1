#!/usr/bin/env bash
# operator-upgrade.sh WORKFLOW_NAME CLUSTER TARGET_VERSION TIMEOUT_SECONDS
# tpg-upgrade component=operator, one cluster:
#   1 guards     every instance Running; no downgrade; nothing to do when already at the target
#   2 backup     optional full backup of every Running instance (P_PRE_BACKUP=true)
#   3 Git        clusters.<cluster>.operator.version in clusters/fleet.yaml (PUSH_MODE direct | pr)
#   4 sync       wait for the ApplicationSet to render the new version, sync, verify operator and instances
# P_DRY_RUN=true records the plan and changes nothing.
WF="$1"; C="$2"; TIMEOUT="$4"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
TARGET="$(norm_operator_version "$3")"
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"

fail() { record "result.${C}" FAILED "$1" "${2:-}"; exit 1; }
result_guard "result.${C}"
use_cluster "$C" || fail NOT_REGISTERED
app="tpg-${C}-operator"
REPO="$WORK/repo"
git_clone "$REPO"
current="$(C="$C" yq -r '.clusters[strenv(C)].operator.version // ""' "$REPO/$FLEET_REL")"
[[ -n "$current" ]] || fail NOT_IN_FLEET "clusters.${C}.operator.version is not declared (run tpg-day0)"
if [[ "$current" == "$TARGET" ]]; then
  record "result.${C}" SUCCEEDED ALREADY_AT_TARGET "$TARGET" "$current"
  exit 0
fi
if [[ "$(printf '%s\n%s\n' "${current#v}" "${TARGET#v}" | sort -V | tail -n1)" != "${TARGET#v}" ]]; then
  fail DOWNGRADE_NOT_SUPPORTED "${current} -> ${TARGET}"
fi
for i in $(inventory_instances "$C"); do
  [[ "$(pg_state "$i")" == "Running" ]] || fail INSTANCE_NOT_RUNNING_BEFORE "$i"
done
if [[ "${P_DRY_RUN:-false}" == "true" ]]; then
  record "result.${C}" SUCCEEDED DRY_RUN "would upgrade ${current} -> ${TARGET}; preUpgradeBackup=${P_PRE_BACKUP:-true}" "$current"
  exit 0
fi

if [[ "${P_PRE_BACKUP:-true}" == "true" ]]; then
  for i in $(inventory_instances "$C"); do
    RESULT_KEY="backup.${C}.${i}" bash /scripts/backup-instance.sh "$WF" "$C" "$i" full "$TIMEOUT"
    b="$(run_data "backup.${C}.${i}")"
    case "$(jq -r '.status' <<<"$b")" in
      SUCCEEDED) ;;
      *) fail PRE_UPGRADE_BACKUP_FAILED "${i}: $(jq -r '.status + " " + .reason + " " + .detail' <<<"$b")" ;;
    esac
  done
fi

TARGET="$TARGET" C="$C" yq -i '.clusters[strenv(C)].operator.version = strenv(TARGET)' "$REPO/$FLEET_REL"
git_commit_push "$REPO" "operator ${C} ${current} -> ${TARGET} (${WF})" "$FLEET_REL" || fail GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"

appset_refresh tpg-operator
start="$(date +%s)"
until [[ "$(app_target_revision "$app")" == "$TARGET" ]]; do
  (( $(date +%s) - start > 600 )) && fail APPSET_NOT_UPDATED "$app targetRevision"
  sleep 15
done
app_refresh "$app"
app_sync "$app" || fail SYNC_REQUEST_FAILED "$app"
app_wait "$app" "$TIMEOUT" || fail SYNC_FAILED "$app"
tk -n tanzu-postgres-operator wait deploy -l app=postgres-operator \
  --for=condition=Available --timeout=600s >/dev/null || fail OPERATOR_NOT_AVAILABLE
image="$(tk -n tanzu-postgres-operator get deploy -l app=postgres-operator \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].image}')"

for i in $(inventory_instances "$C"); do
  pg_wait_running "$i" "$TIMEOUT" || fail INSTANCE_NOT_RUNNING_AFTER "$i"
  sts_wait_ready "$i" 900 || fail REPLICAS_NOT_READY "$i"
done
record "result.${C}" SUCCEEDED "" "operator ${TARGET}, image ${image}" "$current"
