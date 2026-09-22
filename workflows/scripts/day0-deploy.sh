#!/usr/bin/env bash
# day0-deploy.sh WORKFLOW_NAME CLUSTER SYNC_TIMEOUT_SECONDS [INSTALL_ADDONS]
# Prepare the namespaces, install the Helm add-ons (cert-manager, the Vault Secrets
# Operator, and the monitoring agent for the standalone option) when
# INSTALL_ADDONS=true, sync the platform, operator and instance Applications,
# then verify every instance. The regsecret and backup-storage Secrets come from
# Vault through VaultStaticSecrets (platform/base and charts/tpg-instance).
# Exits 1 on failure so later batches do not run.
# MONITORING_OPTION (environment) overrides tpg-settings monitoringOption.
# EXISTING_ADDONS (environment): skip (default) or upgrade add-on releases that already exist.
WF="$1"; C="$2"; TIMEOUT="$3"; INSTALL_ADDONS="${4:-true}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

fail() { record "result.${C}" FAILED "$1" "${2:-}"; exit 1; }
result_guard "result.${C}"

use_cluster "$C" || fail NOT_REGISTERED
INSTANCES="$(inventory_instances "$C")"

# ---- Step 2: prepare
log "preparing namespaces on ${C}"
for ns in tanzu-postgres-operator $(for i in $INSTANCES; do echo "pg-$i"; done); do
  tk create namespace "$ns" --dry-run=client -o yaml | tk apply -f - >/dev/null
  tk label namespace "$ns" tpg.fleet/managed=true --overwrite >/dev/null
done

# ---- Step 3: Helm add-ons and platform components
if [[ "$INSTALL_ADDONS" == "true" ]]; then
  bash /scripts/addons-cluster.sh "$WF" "$C" auto false "result.${C}.addons" "${EXISTING_ADDONS:-skip}" \
    || fail ADDONS_FAILED "see result ${C}.addons"
fi
tk wait --for=condition=Established --timeout=60s crd/certificates.cert-manager.io >/dev/null 2>&1 \
  || fail CERT_MANAGER_NOT_AVAILABLE "install it with tpg-helm-addons or installAddons=true"
if ! tk wait --for=condition=Established --timeout=60s crd/vaultstaticsecrets.secrets.hashicorp.com >/dev/null 2>&1 \
   || ! tk -n tpg-vault get vaultauth tpg-vault >/dev/null 2>&1; then
  fail VSO_NOT_AVAILABLE "Vault Secrets Operator or VaultAuth tpg-vault/tpg-vault missing: run tpg-helm-addons or installAddons=true"
fi

wait_secret() {  # wait_secret NAMESPACE NAME: the VaultStaticSecret has created the Secret
  local _
  for _ in $(seq 1 30); do
    tk -n "$1" get secret "$2" >/dev/null 2>&1 && return 0
    sleep 10
  done
  log "$1/$2: $(tk -n "$1" get vaultstaticsecret "$2" -o json 2>/dev/null \
    | jq -r '[.status.conditions[]? | .type + "=" + .status + " " + .message] | join("; ")')"
  return 1
}

wait_generated() {  # wait_generated APP APPLICATIONSET
  app_exists "$1" && return 0
  appset_refresh "$2"
  for _ in $(seq 1 40); do
    app_exists "$1" && return 0
    sleep 15
  done
  return 1
}
for comp in platform operator; do
  app="tpg-${C}-${comp}"
  wait_generated "$app" "tpg-${comp}" || fail APP_NOT_GENERATED "$app"
  app_refresh "$app"
  app_sync "$app" || fail SYNC_REQUEST_FAILED "$app"
  app_wait "$app" "$TIMEOUT" || fail SYNC_FAILED "$app"
  if [[ "$comp" == "platform" ]]; then
    # The operator images need the pull Secret synced from Vault
    wait_secret tanzu-postgres-operator regsecret || fail SECRET_NOT_SYNCED "tanzu-postgres-operator/regsecret (Vault tpg/shared/broadcom-registry)"
  fi
done
tk wait --for=condition=Established --timeout=300s crd/postgres.sql.tanzu.vmware.com >/dev/null \
  || fail CRD_NOT_ESTABLISHED
tk -n tanzu-postgres-operator wait deploy -l app=postgres-operator \
  --for=condition=Available --timeout=600s >/dev/null || fail OPERATOR_NOT_AVAILABLE

# Versions declared in Git must exist now that the operator is installed
while read -r v; do
  [[ -z "$v" ]] && continue
  tk get postgresversion "$v" >/dev/null 2>&1 || fail VERSION_NOT_AVAILABLE "$v"
done < <(inventory_cluster "$C" | jq -r '.instances[].postgresVersion' | sort -u)

# ---- Step 4: instances
for i in $INSTANCES; do
  rc=0
  sync_instance_app "$C" "$i" "$TIMEOUT" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "$( [[ "$rc" -eq 3 ]] && echo APP_NOT_GENERATED || echo SYNC_FAILED )" "tpg-${C}-${i}"
done

# ---- Step 5: verify
details=()
for i in $INSTANCES; do
  pg_wait_running "$i" "$TIMEOUT" || fail INSTANCE_NOT_RUNNING "$i"
  sts_wait_ready "$i" 600 || fail REPLICAS_NOT_READY "$i"
  for sec in regsecret backup-storage; do
    wait_secret "pg-$i" "$sec" || fail SECRET_NOT_SYNCED "pg-$i/$sec from Vault"
  done
  stanza="$(tk -n "pg-$i" get postgres "$i" -o jsonpath='{.status.stanzaName}' 2>/dev/null || true)"
  [[ -n "$stanza" ]] || fail BACKUP_LOCATION_NOT_INITIALIZED "$i"
  details+=("${i}:Running")
done
record "result.${C}" SUCCEEDED "" "$(IFS=' '; echo "${details[*]:-no instances}")"
