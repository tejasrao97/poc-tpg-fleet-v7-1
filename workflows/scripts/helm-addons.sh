#!/usr/bin/env bash
# helm-addons.sh: install or upgrade the fleet add-ons as Helm releases on one cluster,
# after a pre-check of what is already installed.
#
#   component     role          release                  chart                               namespace
#   cert-manager  target        cert-manager             jetstack/cert-manager               cert-manager
#   monitoring    hub           kps                      kube-prometheus-stack               monitoring
#                                                        + monitoring/standalone/hub (kubectl apply -k)
#   monitoring    target        kps (agent), tpg-ksm     kube-prometheus-stack, kube-state-metrics
#                                                        + monitoring/standalone/targets (kubectl apply -k)
#   vso           hub, target   vault-secrets-operator   hashicorp/vault-secrets-operator    vault-secrets-operator-system
#                                                        + VaultConnection/VaultAuth tpg-vault (vault/tpg-vault-objects.yaml)
#   vault         hub           vault                    hashicorp/vault (server + injector) vault
#
# Used by tpg-aks-infra scripts/steps/35-vault.sh (vault and vso on the hub),
# scripts/steps/45-helm-addons.sh (workstation) and by the tpg-helm-addons and
# tpg-day0 workflows (targets only).
#
# Pre-check, per release, before anything changes:
#   NOT_INSTALLED   nothing found                         -> install
#   OURS            our release in the expected namespace -> compare chart version and values:
#                     same version and values             -> UP_TO_DATE (nothing to do)
#                     installed chart newer than target   -> SKIPPED_NEWER (never downgrade)
#                     otherwise show the version change and the values diff, then act on
#                     --existing: ask (prompt: upgrade, skip or abort), upgrade, skip or abort
#   OTHER_RELEASE   the same chart as another Helm release (other name or namespace)
#   NOT_HELM        the component's CRDs or controller exist without a Helm release
#                   -> reuse it when compatible (REUSED_EXISTING), otherwise BLOCKED:
#                        cert-manager  controller available and version >= v1.14.0
#                        vso           controller available and version >= 0.9.0
#                        kps, vault    never reused: the fleet needs its own configuration
#                   tpg-ksm is not checked for foreign copies: several kube-state-metrics
#                   instances coexist without conflict.
# Every result is printed on stdout as: ADDON <release> <STATUS> <detail>
#
# Usage:
#   helm-addons.sh --cluster NAME --role hub|target --components LIST --fleet-dir DIR
#     [--kubeconfig FILE] [--context CTX] [--remote-write-url URL]
#     [--existing ask|upgrade|skip|abort] [--dry-run]
#     [--vault-addr URL --vault-ca-file FILE --vault-auth-mount MOUNT --vault-auth-role ROLE]  (vso)
# LIST: comma-separated cert-manager, monitoring, vso, vault.
# --existing defaults to ADDONS_EXISTING, else ask on a terminal and skip without one.
#
# Component vault reads VAULT_UNSEAL_MODE (shamir | azure-keyvault) and, for
# azure-keyvault, VAULT_AKV_TENANT_ID, VAULT_AKV_NAME, VAULT_AKV_KEY_NAME and
# VAULT_AKV_CLIENT_ID from the environment.
#
# Hub monitoring: Grafana reads its admin credentials from Secret monitoring/grafana-admin.
# The script creates it before the install when it is missing, with GRAFANA_ADMIN_PASSWORD
# from the environment or a generated 24-character password. The password is never
# written to a file. On success the hub run prints REMOTE_WRITE_URL=<url>.
# KPS_HUB_EXTRA_VALUES: optional comma-separated extra values files for the hub release,
# relative to --fleet-dir (for example monitoring/grafana/smtp/grafana-smtp-values.yaml).
set -euo pipefail

CERT_MANAGER_VERSION="v1.21.2"
KPS_VERSION="91.4.0"
KSM_VERSION="8.5.0"
VSO_VERSION="1.5.1"
VAULT_CHART_VERSION="0.34.1"
JETSTACK_REPO="https://charts.jetstack.io"
PROM_REPO="https://prometheus-community.github.io/helm-charts"
HASHICORP_REPO="https://helm.releases.hashicorp.com"
CERT_MANAGER_MIN="1.14.0"
VSO_MIN="0.9.0"

CLUSTER="" ROLE="" COMPONENTS="" FLEET_DIR="" KUBECONFIG_FILE="" CONTEXT="" RW_URL="" DRY_RUN=0
EXISTING="${ADDONS_EXISTING:-}"
VAULT_ADDR_ARG="" VAULT_CA_FILE="" VAULT_AUTH_MOUNT="" VAULT_AUTH_ROLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --components) COMPONENTS="$2"; shift 2 ;;
    --fleet-dir) FLEET_DIR="$2"; shift 2 ;;
    --kubeconfig) KUBECONFIG_FILE="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --remote-write-url) RW_URL="$2"; shift 2 ;;
    --existing) EXISTING="$2"; shift 2 ;;
    --vault-addr) VAULT_ADDR_ARG="$2"; shift 2 ;;
    --vault-ca-file) VAULT_CA_FILE="$2"; shift 2 ;;
    --vault-auth-mount) VAULT_AUTH_MOUNT="$2"; shift 2 ;;
    --vault-auth-role) VAULT_AUTH_ROLE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '[helm-addons %s] %s\n' "$CLUSTER" "$*" >&2; }
die() { say "ERROR: $*"; exit 1; }
result() { printf 'ADDON %s %s %s\n' "$1" "$2" "${3:-}"; say "$1: $2${3:+ ($3)}"; }
blocked() { result "$1" BLOCKED "$2"; exit 1; }
[[ -n "$CLUSTER" && -n "$COMPONENTS" && -d "$FLEET_DIR" ]] || die "--cluster, --components and --fleet-dir are required"
[[ "$ROLE" == "hub" || "$ROLE" == "target" ]] || die "--role must be hub or target"
if [[ -z "$EXISTING" ]]; then
  if [[ -r /dev/tty ]] && [[ -t 2 ]]; then EXISTING=ask; else EXISTING=skip; fi
fi
case "$EXISTING" in ask|upgrade|skip|abort) ;; *) die "--existing must be ask, upgrade, skip or abort (got ${EXISTING})" ;; esac
command -v helm >/dev/null || die "helm is required"
command -v yq >/dev/null || die "yq (mikefarah v4) is required"

KARGS=(); HARGS=()
if [[ -n "$KUBECONFIG_FILE" ]]; then KARGS+=(--kubeconfig "$KUBECONFIG_FILE"); HARGS+=(--kubeconfig "$KUBECONFIG_FILE"); fi
if [[ -n "$CONTEXT" ]]; then KARGS+=(--context "$CONTEXT"); HARGS+=(--kube-context "$CONTEXT"); fi
k() { kubectl "${KARGS[@]}" "$@"; }
h() { helm "${HARGS[@]}" "$@"; }

# Every release state, whatever the Helm major version.
#
# Helm 3 lists deployed, failed and pending releases by default and needs -a
# (--all) for superseded, uninstalled and uninstalling. Helm 4 removed -a and
# lists every state by default, so "helm list -a" fails there with
# "unknown shorthand flag: 'a'". The per-state flags below exist in both Helm 3
# and Helm 4 and select the same set on either, so the scripts never branch on
# the Helm version. tests/cli-flags checks that -a does not come back.
HELM_LIST_ALL=(--deployed --failed --pending --superseded --uninstalled --uninstalling)

# hlist [helm list args...] -> JSON of every release state
hlist() { h list "${HELM_LIST_ALL[@]}" -o json "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------------- values
# merge_values OUT FILE...: deep-merge values files (later wins, lists replaced,
# like Helm). One merged file keeps "helm get values" comparable with this run.
merge_values() {
  local out="$1"; shift
  if [[ $# -eq 0 ]]; then echo '{}' > "$out"; return; fi
  # shellcheck disable=SC2016  # yq variables
  yq eval-all '. as $item ireduce ({}; . * $item)' "$@" > "$out"
}

overlay() {
  # overlay NAME YQ_EXPRESSION: write a values overlay built with yq -n
  local f="$TMP/overlay-$1.yaml"
  yq -n "$2" > "$f"
  printf '%s' "$f"
}

# ----------------------------------------------------------------- versions
norm_ver() { local v="${1#v}"; printf '%s' "${v%%[-+]*}"; }
ver_ge() {  # ver_ge A B -> 0 when A >= B
  [[ "$(printf '%s\n%s\n' "$(norm_ver "$2")" "$(norm_ver "$1")" | sort -V | head -n1)" == "$(norm_ver "$2")" ]]
}
ver_gt() { ! ver_ge "$2" "$1"; }

# ----------------------------------------------------------------- pre-check
# classify RELEASE NS CHART -> STATUS on stdout: NOT_INSTALLED | OURS | OTHER_RELEASE:<ns>/<name> | NOT_HELM
classify() {
  local rel="$1" ns="$2" chart="$3" other
  if h status "$rel" -n "$ns" >/dev/null 2>&1; then echo OURS; return; fi
  other="$(hlist -A 2>/dev/null | jq -r --arg c "$chart" --arg r "$rel" --arg n "$ns" '
    [.[] | select((.chart | test("^" + $c + "-v?[0-9]")) and ((.name != $r) or (.namespace != $n)))
     | .namespace + "/" + .name] | first // empty')"
  if [[ -n "$other" ]]; then echo "OTHER_RELEASE:${other}"; return; fi
  case "$rel" in
    cert-manager)
      if k get crd certificates.cert-manager.io >/dev/null 2>&1 || [[ -n "$(foreign_image jetstack/cert-manager-controller)" ]]; then echo NOT_HELM; return; fi ;;
    kps)
      if k get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1 || [[ -n "$(foreign_image prometheus-operator/prometheus-operator)" ]]; then echo NOT_HELM; return; fi ;;
    vault-secrets-operator)
      if [[ -n "$(foreign_image hashicorp/vault-secrets-operator)" ]]; then echo NOT_HELM; return; fi
      if k get crd vaultstaticsecrets.secrets.hashicorp.com >/dev/null 2>&1; then
        say "VSO CRDs exist without a controller (left over from an earlier install); installing"
      fi ;;
    vault)
      if [[ -n "$(k get statefulset -A -o json 2>/dev/null | jq -r '[.items[] | select(any(.spec.template.spec.containers[]; .image | test("(^|/)(hashicorp/)?vault:"))) | .metadata.namespace + "/" + .metadata.name] | first // empty')" ]]; then
        echo NOT_HELM; return
      fi ;;
  esac
  echo NOT_INSTALLED
}

# foreign_image PATTERN -> "<ns>/<deployment> <image>" of the first Deployment running PATTERN
foreign_image() {
  k get deploy -A -o json 2>/dev/null | jq -r --arg p "$1" '
    [.items[] | . as $d | .spec.template.spec.containers[] | select(.image | contains($p))
     | $d.metadata.namespace + "/" + $d.metadata.name + " " + .image] | first // empty'
}

image_version() { sed -E 's/@.*$//; s/^.*:([^:\/]+)$/\1/' <<<"$1"; }

deploy_available() {  # deploy_available NS/NAME
  k -n "${1%%/*}" get deploy "${1##*/}" -o json 2>/dev/null \
    | jq -e '(.status.availableReplicas // 0) > 0' >/dev/null
}

# class_text CLASS -> the class in words, for the ADDON detail
class_text() {
  case "$1" in
    OTHER_RELEASE:*) printf 'already installed by Helm release %s' "${1#OTHER_RELEASE:}" ;;
    NOT_HELM) printf 'already installed outside Helm' ;;
    *) printf '%s' "$1" ;;
  esac
}

# reuse_check RELEASE CLASS -> 0 and prints the detail when the foreign installation is usable
reuse_check() {
  local rel="$1" class found dep img ver min
  class="$(class_text "$2")"
  case "$rel" in
    cert-manager) found="$(foreign_image jetstack/cert-manager-controller)"; min="$CERT_MANAGER_MIN" ;;
    vault-secrets-operator) found="$(foreign_image hashicorp/vault-secrets-operator)"; min="$VSO_MIN" ;;
    *) echo "${class}, and the fleet needs its own ${rel} configuration: that installation cannot be reused"; return 1 ;;
  esac
  if [[ -z "$found" ]]; then
    echo "${class}, but no running controller was found (leftover CRDs?)"; return 1
  fi
  dep="${found%% *}"; img="${found#* }"; ver="$(image_version "$img")"
  if ! deploy_available "$dep"; then
    echo "${class}, but ${dep} (${img}) is not available"; return 1
  fi
  if ! ver_ge "$ver" "$min"; then
    echo "${class}: ${dep} runs ${ver}, the fleet needs ${min} or later"; return 1
  fi
  echo "${class}: reusing ${dep} ${ver}"
}

# values_diff RELEASE NS MERGED -> unified diff on stdout (empty when equal)
values_diff() {
  local rel="$1" ns="$2" merged="$3"
  h get values "$rel" -n "$ns" -o yaml 2>/dev/null | yq -P 'sort_keys(..)' > "$TMP/installed.yaml" || true
  [[ -s "$TMP/installed.yaml" ]] && [[ "$(cat "$TMP/installed.yaml")" != "null" ]] || echo '{}' > "$TMP/installed.yaml"
  yq -P 'sort_keys(..)' "$merged" > "$TMP/target.yaml"
  diff -u --label "installed values" --label "values of this run" "$TMP/installed.yaml" "$TMP/target.yaml" || true
}

ask_existing() {  # ask_existing RELEASE -> upgrade | skip | abort on stdout
  local answer
  while true; do
    printf '\n%s on %s: upgrade, skip or abort? [u/s/a] ' "$1" "$CLUSTER" > /dev/tty
    read -r answer < /dev/tty || answer=a
    case "$answer" in
      u|U|upgrade) echo upgrade; return ;;
      s|S|skip) echo skip; return ;;
      a|A|abort) echo abort; return ;;
    esac
  done
}

# decide RELEASE NS CHART VERSION MERGED [NOTE] -> sets ACTION: install | upgrade | none
# (none: nothing to do or foreign installation reused). Prints the ADDON result for none.
decide() {
  local rel="$1" ns="$2" chart="$3" version="$4" merged="$5" note="${6:-}" class st cur cur_app d choice detail
  class="$(classify "$rel" "$ns" "$chart")"
  case "$class" in
    NOT_INSTALLED)
      ACTION=install ;;
    OURS)
      st="$(h status "$rel" -n "$ns" -o json)"
      case "$(jq -r '.info.status' <<<"$st")" in
        pending-*) blocked "$rel" "release ${ns}/${rel} has an operation in progress ($(jq -r '.info.status' <<<"$st"))" ;;
      esac
      # One list call; app_version is app_version in Helm 3 and 4, appVersion in
      # some wrappers, so both spellings are read.
      local row
      row="$(hlist -n "$ns" | jq -c --arg r "$rel" '[.[] | select(.name == $r)][0] // {}')"
      cur="$(jq -r '.chart // ""' <<<"$row" | sed -E "s/^${chart}-//")"
      cur_app="$(jq -r '.app_version // .appVersion // ""' <<<"$row")"
      if ver_gt "$cur" "$version"; then
        ACTION=none; result "$rel" SKIPPED_NEWER "installed chart ${cur} is newer than ${version}; no downgrade"; return
      fi
      d="$(values_diff "$rel" "$ns" "$merged")"
      if [[ "$(norm_ver "$cur")" == "$(norm_ver "$version")" && -z "$d" && "$(jq -r '.info.status' <<<"$st")" == "deployed" ]]; then
        ACTION=none; result "$rel" UP_TO_DATE "chart ${cur}, values unchanged"; return
      fi
      {
        printf '\n=== %s: Helm release %s/%s is already installed ===\n' "$CLUSTER" "$ns" "$rel"
        printf '  status:        %s\n' "$(jq -r '.info.status' <<<"$st")"
        printf '  chart:         %s %s -> %s\n' "$chart" "$cur" "$version"
        printf '  app version:   %s (installed)\n' "$cur_app"
        [[ -z "$note" ]] || printf '  note:          %s\n' "$note"
        if [[ -n "$d" ]]; then printf '  values diff:\n    %s\n' "${d//$'\n'/$'\n'    }"; else printf '  values:        unchanged\n'; fi
      } >&2
      choice="$EXISTING"
      [[ "$choice" != "ask" ]] || choice="$(ask_existing "$rel")"
      case "$choice" in
        upgrade) ACTION=upgrade ;;
        skip) ACTION=none; result "$rel" SKIPPED_EXISTS "chart ${cur} kept (target ${version}); rerun with --existing upgrade to apply" ;;
        abort) blocked "$rel" "ABORTED: the release exists and the operator chose abort (--existing ${EXISTING})" ;;
      esac ;;
    OTHER_RELEASE:*|NOT_HELM)
      if detail="$(reuse_check "$rel" "$class")"; then
        ACTION=none; result "$rel" REUSED_EXISTING "$detail"
      else
        blocked "$rel" "$detail"
      fi ;;
  esac
}

# release NAME CHART VERSION REPO NAMESPACE MERGED [NOTE] [extra helm args...]
release() {
  local name="$1" chart="$2" version="$3" repo="$4" ns="$5" merged="$6" note="${7:-}" wait=(--wait --timeout 15m)
  shift 7
  [[ "${NO_WAIT:-0}" == "1" ]] && wait=()
  decide "$name" "$ns" "$chart" "$version" "$merged" "$note"
  [[ "$ACTION" != "none" ]] || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    h upgrade --install "$name" "$chart" --repo "$repo" --version "$version" -n "$ns" --create-namespace \
      -f "$merged" --dry-run=server "$@" >/dev/null
    result "$name" DRY_RUN "would ${ACTION} ${chart} ${version} in ${ns}"
    return 0
  fi
  say "helm upgrade --install ${name} (${chart} ${version}) in ${ns}"
  h upgrade --install "$name" "$chart" --repo "$repo" --version "$version" -n "$ns" --create-namespace \
    -f "$merged" "${wait[@]}" "$@" >/dev/null
  local rev
  rev="$(h status "$name" -n "$ns" -o json | jq -r '(.version | tostring) + " " + .info.status')"
  if [[ "$ACTION" == "install" ]]; then result "$name" INSTALLED "${chart} ${version}, revision ${rev}"
  else result "$name" UPGRADED "${chart} ${version}, revision ${rev}"; fi
}

# ----------------------------------------------------------------- components
cert_manager() {
  local m="$TMP/cert-manager.yaml"
  merge_values "$m" "$(overlay cert-manager '.crds.enabled = true')"
  release cert-manager cert-manager "$CERT_MANAGER_VERSION" "$JETSTACK_REPO" cert-manager "$m" ""
  [[ "$DRY_RUN" -eq 1 ]] || k -n cert-manager wait deploy --all --for=condition=Available --timeout=300s >/dev/null 2>&1 \
    || [[ "$ACTION" == "none" ]] || die "cert-manager Deployments are not Available"
}

grafana_admin_secret() {
  if k -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    say "Secret monitoring/grafana-admin exists; keeping it"
    return
  fi
  local pw="${GRAFANA_ADMIN_PASSWORD:-}" src="GRAFANA_ADMIN_PASSWORD"
  if [[ -z "$pw" ]]; then
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
    src="generated"
  fi
  [[ "${#pw}" -ge 12 ]] || die "the Grafana admin password must have at least 12 characters"
  if [[ "$DRY_RUN" -eq 1 ]]; then say "dry run: would create Secret monitoring/grafana-admin (${src} password)"; return; fi
  k create namespace monitoring --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$pw" >/dev/null
  say "created Secret monitoring/grafana-admin (${src} password). Read it with:"
  say "  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
}

monitoring_hub() {
  # raw defaults to empty: the script runs with set -u, and an unset
  # KPS_HUB_EXTRA_VALUES would otherwise abort the hub monitoring install with
  # "KPS_HUB_EXTRA_VALUES: unbound variable" before anything is installed.
  local f raw="${KPS_HUB_EXTRA_VALUES:-}"
  local files=("$FLEET_DIR/monitoring/standalone/hub/kps-values.yaml"
               "$FLEET_DIR/monitoring/grafana/alerts/grafana-alerting-values.yaml") m="$TMP/kps-hub.yaml"
  for f in ${raw//,/ }; do
    [[ "$f" == /* ]] || f="$FLEET_DIR/$f"
    [[ -f "$f" ]] || die "KPS_HUB_EXTRA_VALUES file not found: $f"
    files+=("$f")
  done
  merge_values "$m" "${files[@]}"
  grafana_admin_secret
  release kps kube-prometheus-stack "$KPS_VERSION" "$PROM_REPO" monitoring "$m" ""
  [[ "$DRY_RUN" -eq 1 ]] && return
  k apply -k "$FLEET_DIR/monitoring/standalone/hub" >/dev/null
  say "applied monitoring/standalone/hub (dashboard, ServiceMonitors, PrometheusRule)"
  local ip=""
  for _ in $(seq 1 40); do
    ip="$(k -n monitoring get svc -o json | jq -r '
      [.items[] | select(.spec.type == "LoadBalancer" and (.metadata.labels.release // "") == "kps"
        and ([.spec.ports[].port] | index(9090)))][0].status.loadBalancer.ingress[0].ip // empty')"
    [[ -n "$ip" ]] && break
    sleep 15
  done
  [[ -n "$ip" ]] || die "hub Prometheus load balancer has no IP after 10 minutes"
  printf 'REMOTE_WRITE_URL=http://%s:9090/api/v1/write\n' "$ip"
}

monitoring_target() {
  [[ -n "$RW_URL" ]] || die "--remote-write-url is required for target monitoring (the hub Prometheus remote write URL)"
  local m="$TMP/kps-target.yaml" s="$TMP/ksm.yaml"
  merge_values "$m" "$FLEET_DIR/monitoring/standalone/targets/kps-values.yaml" \
    "$(CL="$CLUSTER" RW="$RW_URL" overlay kps-target '.prometheus.prometheusSpec.externalLabels.cluster = strenv(CL)
      | .prometheus.prometheusSpec.remoteWrite = [{"url": strenv(RW)}]')"
  release kps kube-prometheus-stack "$KPS_VERSION" "$PROM_REPO" monitoring "$m" ""
  merge_values "$s" "$FLEET_DIR/monitoring/ksm/values.yaml" "$(overlay ksm '.prometheus.monitor.enabled = true')"
  release tpg-ksm kube-state-metrics "$KSM_VERSION" "$PROM_REPO" monitoring "$s" ""
  [[ "$DRY_RUN" -eq 1 ]] && return
  k apply -k "$FLEET_DIR/monitoring/standalone/targets" -n monitoring >/dev/null
  say "applied monitoring/standalone/targets (PodMonitor, ServiceMonitors)"
}

vso() {
  [[ -n "$VAULT_ADDR_ARG" && -f "$VAULT_CA_FILE" && -n "$VAULT_AUTH_MOUNT" && -n "$VAULT_AUTH_ROLE" ]] \
    || die "component vso needs --vault-addr, --vault-ca-file, --vault-auth-mount and --vault-auth-role"
  local m="$TMP/vso.yaml" allowed="*"
  [[ "$ROLE" == "hub" ]] && allowed="argocd"
  merge_values "$m" "$FLEET_DIR/vault/vso-values.yaml"
  release vault-secrets-operator vault-secrets-operator "$VSO_VERSION" "$HASHICORP_REPO" vault-secrets-operator-system "$m" ""
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "dry run: would apply VaultConnection and VaultAuth tpg-vault/tpg-vault (${VAULT_ADDR_ARG}, auth/${VAULT_AUTH_MOUNT}, role ${VAULT_AUTH_ROLE})"
    return
  fi
  k wait --for=condition=Established --timeout=120s \
    crd/vaultconnections.secrets.hashicorp.com crd/vaultauths.secrets.hashicorp.com crd/vaultstaticsecrets.secrets.hashicorp.com >/dev/null \
    || die "VSO CRDs are not established"
  k create namespace tpg-vault --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n tpg-vault create secret generic vault-ca --from-file=ca.crt="$VAULT_CA_FILE" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  sed -e "s|@VAULT_ADDR@|${VAULT_ADDR_ARG}|" -e "s|@AUTH_MOUNT@|${VAULT_AUTH_MOUNT}|" \
      -e "s|@AUTH_ROLE@|${VAULT_AUTH_ROLE}|" -e "s|@ALLOWED_NS@|${allowed}|" \
      "$FLEET_DIR/vault/tpg-vault-objects.yaml" | k apply -f - >/dev/null
  say "applied VaultConnection and VaultAuth tpg-vault/tpg-vault (${VAULT_ADDR_ARG}, auth/${VAULT_AUTH_MOUNT}, role ${VAULT_AUTH_ROLE})"
}

vault_server() {
  local mode="${VAULT_UNSEAL_MODE:-shamir}" cfg="$TMP/vault-config.hcl" m="$TMP/vault.yaml" wi="" note=""
  case "$mode" in
    shamir)
      cp "$FLEET_DIR/vault/config-shamir.hcl" "$cfg"
      note="unseal mode shamir: an upgrade restarts vault-0, which then needs 3 unseal keys" ;;
    azure-keyvault)
      local v
      for v in VAULT_AKV_TENANT_ID VAULT_AKV_NAME VAULT_AKV_KEY_NAME VAULT_AKV_CLIENT_ID; do
        [[ "${!v:-}" =~ ^[A-Za-z0-9-]+$ ]] || die "${v} is required for unseal mode azure-keyvault (letters, digits and '-')"
      done
      sed -e "s|@TENANT_ID@|${VAULT_AKV_TENANT_ID}|" -e "s|@KEY_VAULT_NAME@|${VAULT_AKV_NAME}|" \
          -e "s|@KEY_NAME@|${VAULT_AKV_KEY_NAME}|" "$FLEET_DIR/vault/config-azure-keyvault.hcl" > "$cfg"
      # Workload identity: pod label plus the client ID on the ServiceAccount
      wi="$(CID="$VAULT_AKV_CLIENT_ID" overlay vault-wi '.server.extraLabels["azure.workload.identity/use"] = "true"
        | .server.serviceAccount.annotations["azure.workload.identity/client-id"] = strenv(CID)')" ;;
    *) die "VAULT_UNSEAL_MODE must be shamir or azure-keyvault (got ${mode})" ;;
  esac
  local files=("$FLEET_DIR/vault/vault-values.yaml"
               "$(CFG="$cfg" overlay vault-config '.server.standalone.config = load_str(strenv(CFG))
                  | .server.updateStrategyType = "RollingUpdate"')")
  [[ -z "$wi" ]] || files+=("$wi")
  merge_values "$m" "${files[@]}"
  # vault-0 only becomes Ready once initialized and unsealed (35-vault.sh), so no --wait.
  NO_WAIT=1 release vault vault "$VAULT_CHART_VERSION" "$HASHICORP_REPO" vault "$m" "$note"
}

for comp in ${COMPONENTS//,/ }; do
  case "${ROLE}/${comp}" in
    target/cert-manager) cert_manager ;;
    hub/cert-manager) say "cert-manager is not installed on the hub (no Postgres instances there); skipping" ;;
    hub/monitoring) monitoring_hub ;;
    target/monitoring) monitoring_target ;;
    */vso) vso ;;
    hub/vault) vault_server ;;
    target/vault) die "component vault is installed on the hub only" ;;
    *) die "unknown component ${comp}" ;;
  esac
done
say "done: ${COMPONENTS} (${ROLE})"
