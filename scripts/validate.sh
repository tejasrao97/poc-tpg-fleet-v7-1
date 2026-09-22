#!/usr/bin/env bash
# Static validation of tpg-fleet. Requires: yamllint, shellcheck, kustomize,
# helm, kubeconform, python3 (PyYAML), jq, yq v4.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

echo "== yamllint";   yamllint -s .
echo "== shellcheck"; shellcheck -x -e SC1091 workflows/scripts/*.sh scripts/*.sh tests/*.sh tests/*/*.sh monitoring/grafana/import-azure-grafana.sh

# Flags the pinned CLIs no longer accept (helm list -a under Helm 4, and the
# rest of tests/cli-flags/rules.yaml), plus helm-addons.sh against a Helm 4 CLI.
echo "== tests"; tests/run-all.sh

echo "== kustomize build"
for d in workflows platform/base monitoring/azure/targets monitoring/azure/hub monitoring/standalone/targets monitoring/standalone/hub; do
  kustomize build "$d" > "$OUT/$(tr / _ <<<"$d").yaml"
  echo "ok $d"
done

echo "== fleet.yaml structure"
yq -e '.clusters | type == "!!map"' clusters/fleet.yaml >/dev/null
for c in $(yq -r '.clusters | keys | .[]' clusters/fleet.yaml); do
  C="$c" yq -e '.clusters[strenv(C)].operator.version | type == "!!str"' clusters/fleet.yaml >/dev/null \
    || { echo "clusters.${c}.operator.version is required" >&2; exit 1; }
  for i in $(C="$c" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' clusters/fleet.yaml); do
    C="$c" I="$i" yq -e '.clusters[strenv(C)].instances[strenv(I)].instance.postgresVersion | test("^postgres-[0-9]")' clusters/fleet.yaml >/dev/null \
      || { echo "clusters.${c}.instances.${i}.instance.postgresVersion is required (postgres-<version>)" >&2; exit 1; }
  done
done
echo "ok clusters/fleet.yaml"

# values_for CLUSTER INSTANCE -> the Helm values the tpg-instances ApplicationSet passes
# shellcheck disable=SC2016  # yq variables, not shell
values_for() {
  C="$1" I="$2" yq '.clusters[strenv(C)] as $c | ($c.instances[strenv(I)] // {}) as $i
    | ($c | with_entries(select(.key != "instances" and .key != "operator")))
    * {"cluster": {"name": strenv(C)}, "backup": {"container": "pg-backups-" + strenv(C)}}
    * $i * {"instance": {"name": strenv(I)}}' clusters/fleet.yaml
}

echo "== helm lint / template (every fleet.yaml instance)"
mkdir -p "$OUT/values"
for c in $(yq -r '.clusters | keys | .[]' clusters/fleet.yaml); do
  for i in $(C="$c" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' clusters/fleet.yaml); do
    values_for "$c" "$i" > "$OUT/values/$c-$i.yaml"
    set -- -f clusters/_template/cluster.yaml -f clusters/_template/instance.yaml -f "$OUT/values/$c-$i.yaml"
    helm lint charts/tpg-instance "$@" >/dev/null
    helm template "$i" charts/tpg-instance "$@" --namespace "pg-$i" > "$OUT/chart_${c}_${i}.yaml"
    # PostgresBackupLocation must not carry the two fields the CRD drops on
    # apply (spec.additionalParameters when empty, spec.storage.azure.forcePathStyle
    # when false). Rendering them makes the Application OutOfSync for good.
    if yq 'select(.kind == "PostgresBackupLocation") | .spec
           | (has("additionalParameters"), (.storage.azure | has("forcePathStyle")))' \
         "$OUT/chart_${c}_${i}.yaml" | grep -qx true; then
      echo "PostgresBackupLocation for ${c}/${i} renders additionalParameters or forcePathStyle;" >&2
      echo "the CRD drops both on apply and the Application never reaches Synced" >&2
      exit 1
    fi
    echo "ok ${c}/${i}"
  done
done

echo "== kubeconform"
cp bootstrap/*.yaml bootstrap/appsets/*.yaml "$OUT/"
for f in bootstrap/monitoring/*/*.yaml; do cp "$f" "$OUT/$(tr / _ <<<"$f")"; done
kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default -schema-location "$CATALOG" "$OUT"/*.yaml

echo "== JSON"
jq -e '.panels | length > 0' monitoring/standalone/hub/dashboards/tpg-fleet.json >/dev/null
for f in monitoring/grafana/alerts/api/*.json; do jq -e '.uid and .data' "$f" >/dev/null; done
echo "ok dashboard and alert payloads"

echo "== generated files are up to date"
python3 monitoring/grafana/generate.py >/dev/null
git diff --quiet -- monitoring || { echo "run monitoring/grafana/generate.py and commit the result" >&2; exit 1; }
echo "All checks passed"
