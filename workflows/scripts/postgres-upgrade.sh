#!/usr/bin/env bash
# postgres-upgrade.sh WORKFLOW_NAME CLUSTER TARGET_VERSION INSTANCES TIMEOUT_SECONDS
# tpg-upgrade component=postgres: upgrade Postgres instances on one cluster with
# PostgresVersionUpgrade. INSTANCES is all or a comma-separated list.
# Minor or major is detected per instance; a major upgrade needs P_ALLOW_MAJOR=true
# and a Succeeded backup from the last 26 hours (P_PRE_BACKUP=true takes one first).
# After the upgrade, clusters.<cluster>.instances.<instance>.instance.postgresVersion is
# written to clusters/fleet.yaml (PUSH_MODE direct | pr) and the Application is synced.
# P_DRY_RUN=true records the plan per instance and changes nothing.
# Records result.<cluster>.<instance>. Exits 1 if any instance FAILED.
WF="$1"; C="$2"; SELECTED="$4"; TIMEOUT="$5"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
TARGET="$(norm_postgres_version "$3")"
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"
[[ "$SELECTED" == "all" ]] || SELECTED="$(split_list "$SELECTED" | paste -sd,)"
ALLOW_MAJOR="${P_ALLOW_MAJOR:-false}"; PRE_BACKUP="${P_PRE_BACKUP:-true}"; DRY="${P_DRY_RUN:-false}"

use_cluster "$C" || { record "result.${C}" FAILED NOT_REGISTERED; exit 1; }
result_guard "result.${C}"
any_failed=0
target_major="$(major_of "$TARGET")"
target_num="$(sed -E 's/^[^0-9]*//' <<<"$TARGET")"

wanted() { [[ "$SELECTED" == "all" ]] || [[ ",${SELECTED}," == *",$1,"* ]]; }

upgrade_one() {
  local i="$1" ns="pg-$1" key="result.${C}.$1" cur cur_major b phase name start j stamp TYPE
  ifail() { record "$key" FAILED "$1" "${2:-}"; any_failed=1; }

  if ! tk get postgresversion "$TARGET" >/dev/null 2>&1; then ifail VERSION_NOT_AVAILABLE "$TARGET"; return; fi
  cur="$(tk -n "$ns" get postgres "$i" -o jsonpath='{.spec.postgresVersion.name}' 2>/dev/null || true)"
  [[ -n "$cur" ]] || cur="$(tk -n "$ns" get postgres "$i" -o jsonpath='{.status.dbVersion}' 2>/dev/null || true)"
  [[ -n "$cur" ]] || { ifail INSTANCE_NOT_FOUND; return; }
  if [[ "$cur" == "$TARGET" ]]; then record "$key" SUCCEEDED ALREADY_AT_TARGET "$TARGET"; return; fi
  cur_major="$(major_of "$cur")"
  TYPE=minor
  if (( target_major > cur_major )); then
    TYPE=major
    [[ "$ALLOW_MAJOR" == "true" ]] || { ifail MAJOR_UPGRADE_NOT_ALLOWED "$cur -> $TARGET is a major upgrade: set allowMajor=true"; return; }
  elif (( target_major < cur_major )); then
    ifail DOWNGRADE_NOT_SUPPORTED "$cur -> $TARGET"; return
  elif [[ "$(printf '%s\n%s\n' "${cur#postgres-}" "${TARGET#postgres-}" | sort -V | tail -n1)" != "${TARGET#postgres-}" ]]; then
    ifail DOWNGRADE_NOT_SUPPORTED "$cur -> $TARGET"; return
  fi

  if [[ "$(pg_state "$i")" != "Running" ]]; then record "$key" SKIPPED_NOT_RUNNING "$(pg_state "$i")"; return; fi

  busy() {
    b="$(latest_cr postgresbackup "$ns" ".spec.sourceInstance.name == \"$i\"")"
    [[ -n "$b" ]] && [[ "$(jq -r '.status.phase // ""' <<<"$b")" =~ ^(|Pending|Running)$ ]]
  }
  if busy; then
    sleep 120
    if busy; then record "$key" SKIPPED_IN_PROGRESS "backup $(jq -r '.metadata.name' <<<"$b") in progress"; return; fi
  fi

  if [[ "$DRY" == "true" ]]; then
    record "$key" SUCCEEDED DRY_RUN "would run a ${TYPE} upgrade ${cur} -> ${TARGET}; preUpgradeBackup=${PRE_BACKUP}" "$cur"
    return
  fi

  if [[ "$PRE_BACKUP" == "true" ]]; then
    RESULT_KEY="backup.${C}.${i}" bash /scripts/backup-instance.sh "$WF" "$C" "$i" full "$TIMEOUT"
    case "$(run_data "backup.${C}.${i}" | jq -r '.status')" in
      SUCCEEDED) ;;
      *) ifail PRE_UPGRADE_BACKUP_FAILED "$(run_data "backup.${C}.${i}" | jq -r '.status + " " + .reason + " " + .detail')"; return ;;
    esac
  fi

  if [[ "$TYPE" == "major" ]]; then
    [[ -n "$(tk -n "$ns" get postgres "$i" -o jsonpath='{.spec.backupLocation.name}')" ]] || { ifail NO_BACKUP_LOCATION; return; }
    recent="$(tk -n "$ns" get postgresbackup -o json | jq -r --arg i "$i" '
      [.items[] | select(.spec.sourceInstance.name == $i and .status.phase == "Succeeded" and .status.timeCompleted != null)
       | select((now - (.status.timeCompleted | fromdateiso8601)) < 93600)] | length')"
    [[ "$recent" -gt 0 ]] || { ifail NO_RECENT_BACKUP "no Succeeded backup in the last 26 hours"; return; }
  fi

  stamp="$(date -u +%Y%m%d%H%M)"
  name="${i}-to-$(tr '._' '--' <<<"$TARGET")-${stamp}"
  log "creating PostgresVersionUpgrade ${ns}/${name}"
  tk -n "$ns" apply -f - >/dev/null <<YAML || { ifail CREATE_FAILED; return; }
apiVersion: sql.tanzu.vmware.com/v1
kind: PostgresVersionUpgrade
metadata:
  name: ${name}
  annotations:
    postgres.database/acknowledge-no-backup: "false"
  labels:
    tpg.fleet/workflow: ${WF}
spec:
  postgresInstance:
    name: ${i}
  postgresVersion:
    name: ${TARGET}
YAML

  start="$(date +%s)"
  while true; do
    j="$(tk -n "$ns" get postgresversionupgrade "$name" -o json 2>/dev/null || echo '{}')"
    phase="$(jq -r '.status.phase // ""' <<<"$j")"
    case "$phase" in
      Succeeded) break ;;
      PreCheckFailed|Failed)
        ifail "UPGRADE_${phase^^}" "$(tk -n "$ns" describe postgresversionupgrade "$name" | tail -n 15 | tr '\n' ' ')"
        return ;;
    esac
    if (( $(date +%s) - start > TIMEOUT )); then record "$key" TIMEOUT "" "phase=${phase}"; any_failed=1; return; fi
    sleep 30
  done

  pg_wait_running "$i" 1800 || { ifail NOT_RUNNING_AFTER_UPGRADE; return; }
  sts_wait_ready "$i" 1800 || { ifail REPLICAS_NOT_READY; return; }
  dbv="$(tk -n "$ns" get postgres "$i" -o jsonpath='{.status.dbVersion}')"
  [[ "$dbv" == "$target_num"* ]] || log "WARNING: status.dbVersion=${dbv}, expected ${target_num}"

  # Keep Git in line with the cluster, then sync the instance Application
  C="$C" I="$i" TARGET="$TARGET" yq -i '.clusters[strenv(C)].instances[strenv(I)].instance.postgresVersion = strenv(TARGET)' "$WORK/repo/$FLEET_REL"
  git_commit_push "$WORK/repo" "postgres ${C}/${i} ${cur} -> ${TARGET} (${WF})" "$FLEET_REL" || { ifail GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"; return; }
  app_refresh "tpg-${C}-${i}"
  if ! { app_sync "tpg-${C}-${i}" && app_wait "tpg-${C}-${i}" 900; }; then
    log "WARNING: sync of tpg-${C}-${i} did not complete"
  fi
  record "$key" SUCCEEDED "" "${TYPE} upgrade, dbVersion ${dbv}" "$cur"
}

git_clone "$WORK/repo"
if [[ "$SELECTED" != "all" ]]; then
  for i in $(split_list "$SELECTED"); do
    inventory_instances "$C" | grep -qx "$i" || { record "result.${C}.${i}" FAILED UNKNOWN_INSTANCE "not declared for ${C} in ${FLEET_REL}"; any_failed=1; }
  done
fi
for i in $(inventory_instances "$C"); do
  if ! wanted "$i"; then
    record "result.${C}.${i}" SKIPPED_NOT_SELECTED "" "instances=${SELECTED}"
    continue
  fi
  upgrade_one "$i"
done
exit "$any_failed"
