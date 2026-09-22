#!/usr/bin/env bash
# discover.sh WORKFLOW_NAME CLUSTERS [FLEET_JSON]
# Build the run inventory from the registered clusters (Secret argo/kubeconfig-<cluster>,
# wave from its tpg.fleet/wave label) and clusters/fleet.yaml in tpg-fleet.
# CLUSTERS is "all" (registered clusters that have an entry in fleet.yaml) or a
# comma-separated list. FLEET_JSON, when set, replaces fleet.yaml (tpg-day0 dry runs).
# Outputs:
#   /tmp/inventory.json       [{name, wave, maxReadReplicas, operatorVersion, instances:[...]}]
#   /tmp/instance-items.json  [{cluster, instance, scheduled, retentionDays}]
WF="$1"; SELECTED="$2"; FLEET_JSON="${3:-}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

REPO="$WORK/repo"
git_clone "$REPO"
if [[ -n "$FLEET_JSON" && "$FLEET_JSON" != "{}" ]]; then
  printf '%s' "$FLEET_JSON" | yq -P '.' > "$REPO/$FLEET_REL"
  log "using the fleet.yaml content planned by this run (not pushed)"
fi
registered="$(registered_clusters)"

if [[ "$SELECTED" == "all" ]]; then
  wanted="$(fleet_clusters "$REPO")"
else
  wanted="$(tr ',' '\n' <<<"$SELECTED" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)"
fi

inv="[]"
for c in $wanted; do
  if ! grep -qx "$c" <<<"$registered"; then
    record "result.${c}" FAILED NOT_REGISTERED "Secret argo/kubeconfig-${c} is missing; registered clusters: $(paste -sd, <<<"$registered")"
    continue
  fi
  if ! fleet_has_cluster "$REPO" "$c"; then
    record "result.${c}" FAILED NOT_IN_FLEET "no clusters.${c} entry in ${FLEET_REL} (run tpg-day0 for this cluster)"
    continue
  fi
  instances="[]"
  for i in $(fleet_instances "$REPO" "$c"); do
    ha="$(fleet_instance_value "$REPO" "$c" "$i" '.instance.highAvailability.enabled' true)"
    rr="$(fleet_instance_value "$REPO" "$c" "$i" '.instance.highAvailability.readReplicas' 0)"
    [[ "$ha" == "true" ]] || rr=0
    sched=true
    [[ "$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].backup.scheduled == false' "$REPO/$FLEET_REL")" == "true" ]] && sched=false
    # Backup age limit for tpg-backup-retention: instance override, then cluster override,
    # then clusters/_template/cluster.yaml, then 35 days
    rd="$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].backup.retentionDays | select(. != null)' "$REPO/$FLEET_REL")"
    [[ -n "$rd" && "$rd" != "null" ]] || rd="$(fleet_cluster_value "$REPO" "$c" '.backup.retentionDays' 35)"
    [[ "$rd" =~ ^[0-9]+$ ]] || rd=35
    obj="$(jq -cn --arg n "$i" --arg v "$(fleet_instance_value "$REPO" "$c" "$i" '.instance.postgresVersion' '')" \
      --argjson ha "$ha" --argjson rr "$rr" --argjson s "$sched" --argjson rd "$rd" \
      '{name:$n, postgresVersion:$v, highAvailability:$ha, readReplicas:$rr, scheduledBackups:$s, retentionDays:$rd}')"
    instances="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$instances")"
  done
  obj="$(jq -cn --arg n "$c" \
    --argjson w "$(registered_wave "$c")" \
    --argjson m "$(fleet_cluster_value "$REPO" "$c" '.cluster.maxReadReplicas' 3)" \
    --arg v "$(C="$c" yq -r '.clusters[strenv(C)].operator.version // ""' "$REPO/$FLEET_REL")" \
    --argjson inst "$instances" \
    '{name:$n, wave:$w, maxReadReplicas:$m, operatorVersion:$v, instances:$inst}')"
  inv="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$inv")"
done

printf '%s' "$inv" > /tmp/inventory.json
jq -c '[.[] as $c | $c.instances[] | {cluster: $c.name, instance: .name, scheduled: (.scheduledBackups | tostring),
  retentionDays: (.retentionDays | tostring)}]' <<<"$inv" > /tmp/instance-items.json
kubectl -n "$ARGO_NS" patch configmap "$(run_cm)" --type merge \
  -p "$(jq -cn --arg v "$inv" '{data: {inventory: $v}}')" >/dev/null
log "inventory: $(jq -r 'map(.name + "(" + (.instances | length | tostring) + ")") | join(", ")' <<<"$inv")"
