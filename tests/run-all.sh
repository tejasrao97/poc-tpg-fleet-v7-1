#!/usr/bin/env bash
# Every offline test suite. Usage: tests/run-all.sh [--against-cli]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"

echo "=== tests/cli-flags"
bash "${HERE}/cli-flags/run.sh" ${ARG:+"$ARG"}
echo
echo "=== tests/helm4"
bash "${HERE}/helm4/run.sh"

INFRA="${FLEET_SIBLING:-$(cd "${HERE}/../.." && pwd)/tpg-aks-infra}"
if [[ -x "${INFRA}/tests/verify/run.sh" ]]; then
  echo
  echo "=== tpg-aks-infra tests/verify"
  FLEET_LOCAL_DIR="$(cd "${HERE}/.." && pwd)" bash "${INFRA}/tests/verify/run.sh"
fi
echo
echo "All test suites passed"
