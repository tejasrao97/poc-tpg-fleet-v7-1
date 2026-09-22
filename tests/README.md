# tests

Offline tests. None of them need a cluster, a Helm repository or Azure; they run
from a clone and are part of `scripts/validate.sh`.

```bash
tests/run-all.sh              # everything that runs without extra binaries
tests/run-all.sh --against-cli   # also compare every flag with the installed CLIs
```

| Suite | What it covers | Requires |
|---|---|---|
| `cli-flags/` | Flags the pinned CLI version no longer accepts, in shell scripts, WorkflowTemplates and Markdown | python3 (PyYAML) |
| `helm4/` | `workflows/scripts/helm-addons.sh` end to end against a Helm 4 CLI | python3, jq, yq (mikefarah) |

`tpg-aks-infra/tests/verify/run.sh` covers `scripts/steps/60-verify.sh` and uses
the stubs in `helm4/bin`, so both repositories test against the same fakes.

## cli-flags

A removed CLI flag is invisible to yamllint, shellcheck and kubeconform. It
fails at run time, inside a workflow step, halfway through a deployment. That is
how `helm list -a` reached the fleet: the workflow tools image moved to
`alpine/k8s:1.35.8`, which ships Helm 4, and Helm 4 removed `-a`.

`check_cli_flags.py` reads the commands out of the repository and applies
`rules.yaml`, which lists per tool and subcommand the flags that are gone or
renamed, why, and what to write instead. Add a rule whenever a pinned image
moves to a new major CLI version, and add a line to
`fixtures/violations.sh` for it: `run.sh` asserts that every rule fires exactly
once there and that nothing fires in `fixtures/clean.md`, so a rule that stops
matching, or one that matches too much, fails the suite.

`--against-cli` goes further and asks every installed binary for its own flags
(`<tool> <subcommand> --help`), then reports each flag the repository uses that
the binary does not know. It catches changes nobody has written a rule for yet.
Tools that are not installed are skipped, so it is safe to run anywhere.

## helm4

`bin/helm` and `bin/kubectl` are stubs. The helm stub parses flags the way Helm
4 does: `helm list -a` exits 1 with `unknown shorthand flag: 'a'`, exactly as
the real binary does in the tools image, and `helm registry login` rejects a
host with a path. Cluster and release state come from JSON files, so the add-on
pre-check can be driven through all of its outcomes: `DRY_RUN`, `UP_TO_DATE`,
`SKIPPED_EXISTS`, `SKIPPED_NEWER`, `REUSED_EXISTING` and `BLOCKED`.

The last case in the suite runs `helm list -a` against the stub and fails if it
is accepted, so a green suite cannot mean "the stub accepts anything".
