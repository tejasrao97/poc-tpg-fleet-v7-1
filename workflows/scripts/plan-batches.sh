#!/usr/bin/env bash
# plan-batches.sh WORKFLOW_NAME REQUIRE_PRECHECK MAX_PARALLEL
# Wave 0 clusters run one at a time (canary). Later waves run in batches of
# MAX_PARALLEL, wave by wave. With REQUIRE_PRECHECK=true only PASSED or
# MANAGED clusters are planned. Outputs /tmp/batches.json and /tmp/has-batches.
WF="$1"; REQUIRE="$2"; MAXP="$3"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

[[ "$MAXP" =~ ^[1-9][0-9]*$ ]] || { log "maxParallel must be a positive integer"; exit 1; }
inv="$(run_data inventory)"
[[ -n "$inv" ]] || inv="[]"

eligible="[]"
for c in $(jq -r '.[].name' <<<"$inv"); do
  if [[ "$REQUIRE" == "true" ]]; then
    s="$(record_status "precheck.${c}")"
    [[ "$s" == "PASSED" || "$s" == "MANAGED" ]] || { log "skipping ${c} (precheck ${s:-missing})"; continue; }
  fi
  eligible="$(jq -c --argjson inv "$inv" --arg c "$c" '. + [$inv[] | select(.name == $c)]' <<<"$eligible")"
done

jq -c --argjson n "$MAXP" '
  def chunks($size): [range(0; length; $size) as $i | .[$i:($i + $size)]];
  (map(select(.wave == 0)) | map([.name])) as $canary
  | (map(select(.wave != 0)) | sort_by(.wave) | group_by(.wave)
     | map(map(.name) | chunks($n)) | add // []) as $rest
  | $canary + $rest
' <<<"$eligible" > /tmp/batches.json

if [[ "$(jq 'length' /tmp/batches.json)" -gt 0 ]]; then echo true > /tmp/has-batches; else echo false > /tmp/has-batches; fi
log "batches: $(cat /tmp/batches.json)"
