# tpg-fleet

GitOps repository for the **Tanzu for Postgres on AKS GitOps POC**. Argo CD reads this repository to deploy the Tanzu for Postgres operator and Postgres instances to every target AKS cluster. Argo Workflows on the hub runs the ordered, gated Day 0 and Day 1 operations defined here.

The Azure infrastructure, the Argo installation and the cluster prerequisites live in the companion repository `tpg-aks-infra`.

## Pinned versions

| Component | Version | Where |
|---|---|---|
| Tanzu for Postgres operator chart | v4.5.0 | `clusters/fleet.yaml` (`clusters.<cluster>.operator.version`) |
| Argo CD / chart | v3.5.3 / 10.9.1 | `tpg-aks-infra/argo` |
| Argo Workflows / chart | v4.1.3 / 2.0.6 | `tpg-aks-infra/argo` |
| cert-manager chart | v1.21.2 | `workflows/scripts/helm-addons.sh` (Helm release `cert-manager`) |
| kube-state-metrics chart | 8.5.0 | `bootstrap/monitoring/azure`, `workflows/scripts/helm-addons.sh` (standalone) |
| kube-prometheus-stack chart | 91.4.0 | `workflows/scripts/helm-addons.sh` (Helm release `kps`, standalone) |
| HashiCorp Vault / chart | 2.0.4 / 0.34.1 | `workflows/scripts/helm-addons.sh` (Helm release `vault`, hub), `vault/vault-values.yaml` |
| Vault Secrets Operator chart | 1.5.1 | `workflows/scripts/helm-addons.sh` (Helm release `vault-secrets-operator`) |
| Workflow tools image | `alpine/k8s:1.35.8` | `toolsImage` parameter of every WorkflowTemplate |
| Azure CLI image | `mcr.microsoft.com/azure-cli:2.90.0` | `azCliImage` parameter of `tpg-rotate-credential` |

## Repository layout

```text
tpg-fleet/
  bootstrap/
    project-tpg.yaml                 AppProject tpg
    app-hub-workflows.yaml           Hub Application for workflows/ (automated sync)
    appsets/                         platform, operator, instances (manual sync)
    monitoring/azure/                Option A: kube-state-metrics + azmonitoring monitors
  platform/base/                     StorageClass tpg-data-retain (disk SKU from Terraform, Retain;
                                     the tpg-platform ApplicationSet patches skuName per cluster),
                                     regsecret for the operator namespace (from Vault)
  vault/                             Helm values, server config (shamir and azure-keyvault),
                                     VaultConnection/VaultAuth, policies (tpg-admin, tpg-workflow,
                                     tpg-argocd, tpg-target)
  charts/tpg-instance/               Postgres + PostgresBackupLocation (Azure Blob)
  clusters/
    _template/cluster.yaml           cluster defaults for every cluster (maxReadReplicas, backup)
    _template/instance.yaml          instance defaults for every instance (sizes, HA, resources)
    fleet.yaml                       per cluster: operator.version, overrides, instances.<name> overrides
    deleted/<cluster>/<i>-<time>     instance entries removed by the delete workflows
  docs/
    workflow-commands.md             argo and argocd commands for every workflow, with examples
  workflows/
    kustomization.yaml               WorkflowTemplates, CronWorkflows, RBAC, tpg-scripts ConfigMap
    rbac.yaml                        ServiceAccount tpg-workflow
    scripts/                         step scripts mounted at /scripts (helm-addons.sh is also run by tpg-aks-infra)
    vault-agent/                     Vault Agent templates (ConfigMap tpg-vault-agent) for the workflow pods
    templates/                       tpg-lib, tpg-day0, tpg-upgrade, tpg-scale-instance, tpg-backup,
                                     tpg-backup-retention, tpg-restore, tpg-rotate-credential,
                                     tpg-delete-instance, tpg-delete-apps, tpg-helm-addons
    cron/                            tpg-backup-full (Sun 00:00 UTC), tpg-backup-incr (Mon-Sat 00:00 UTC),
                                     tpg-backup-retention (daily 02:00 UTC)
  monitoring/
    ksm/values.yaml                  custom resource state metrics for Postgres, backups, restores
    azure/, standalone/              monitors, kube-prometheus-stack values, dashboard, PrometheusRules
    grafana/                         generate.py, Grafana alert rules, Azure import script, SMTP examples
    prometheus/                      Alertmanager SMTP example
  scripts/                           set-repo-url.sh, validate.sh
  tests/
    cli-flags/                       flags the pinned CLIs no longer accept (rules.yaml, fixtures)
    helm4/                           helm-addons.sh end to end against a Helm 4 CLI (stub helm, kubectl)
    run-all.sh                       both suites, plus tpg-aks-infra/tests/verify when it is a sibling
```

## One template for every cluster

There is no folder per cluster. Every cluster renders the same chart with the same two template files, and `clusters/fleet.yaml` holds only what differs:

```yaml
clusters:
  aks-tpg-poc-01:                  # registered cluster (Argo CD label tpg.fleet/managed=true)
    operator:
      version: v4.5.0              # required; tpg-day0 and tpg-upgrade write it
    cluster:
      maxReadReplicas: 5           # optional override of _template/cluster.yaml
    instances:
      orders-db:                   # namespace pg-orders-db, Application tpg-aks-tpg-poc-01-orders-db
        instance:
          postgresVersion: postgres-17.6
          highAvailability: {enabled: true, readReplicas: 2}
      billing-db:
        instance:
          postgresVersion: postgres-17.6
```

| Value | Source |
|---|---|
| Which clusters exist, and their wave | Cluster registration in `tpg-aks-infra` (Secret labels `tpg.fleet/managed`, `tpg.fleet/wave`) |
| Operator version, instances and their overrides | `clusters/fleet.yaml` |
| Defaults | `clusters/_template/cluster.yaml`, `clusters/_template/instance.yaml`, then `charts/tpg-instance/values.yaml` |
| `cluster.name`, backup container `pg-backups-<cluster>` | Set by the `tpg-instances` ApplicationSet |

The `tpg-operator` and `tpg-instances` ApplicationSets combine the registered clusters with `clusters/fleet.yaml` (matrix generator with a list generator per cluster). A registered cluster without an entry gets only `tpg-<cluster>-platform` until `tpg-day0` adds it. You normally never edit `fleet.yaml` by hand: the workflows write it, with `pushMode=direct` or `pushMode=pr`.

## Get started

These steps run **before** the first `tpg-aks-infra/scripts/run.sh`. That script
reads this repository from disk (`FLEET_LOCAL_DIR`), not from GitHub: its
`vault`, `addons` and `bootstrap` steps apply files from the clone and run
`workflows/scripts/helm-addons.sh` out of it. A clone that still carries the
`<org>` placeholder fails those steps after the clusters have been changed.

1. Create an empty private GitHub repository named `tpg-fleet`, and clone it
   next to `tpg-aks-infra` (the tests in either repository find the other one
   when they are siblings).

2. Set the repository URL everywhere:

   ```bash
   cd tpg-fleet
   ./scripts/set-repo-url.sh https://github.com/<your-org>/tpg-fleet.git
   git grep -n '<org>' || echo "no placeholders left"
   ```

3. Review `clusters/_template/*.yaml`. The example `clusters/fleet.yaml` declares three clusters; `yq -i '.clusters = {}' clusters/fleet.yaml` starts empty and lets `tpg-day0` add clusters from its inputs.

4. Keep the scripts executable and run the checks. Neither needs a cluster:

   ```bash
   chmod +x scripts/*.sh tests/run-all.sh tests/*/run.sh
   tests/run-all.sh        # CLI flag rules, and helm-addons.sh against a Helm 4 CLI
   ./scripts/validate.sh   # yamllint, shellcheck, kustomize, helm lint/template, kubeconform
   ```

5. Push, so Argo CD and the workflows read the same content:

   ```bash
   git add -A && git commit -m "Set repository URL"
   git remote add origin https://github.com/<your-org>/tpg-fleet.git
   git push -u origin main
   ```

   The checked-out branch must be the one in `FLEET_REPO_REVISION` (`main` by default).

6. In `tpg-aks-infra`, set `env.sh` (`FLEET_LOCAL_DIR` points at this clone) and run `scripts/run.sh` for your scenario (hub with or without Argo; clusters from Terraform or pre-created). Its `addons` step installs the Helm add-ons and its `bootstrap` step applies `bootstrap/`.

### Helm 4

`toolsImage` is `alpine/k8s:1.35.8`, which ships **Helm 4**. Helm 4 removed
the `-a` flag from `helm list` (it lists every release state by default), renamed `--atomic` to
`--rollback-on-failure` and `--force` to `--force-replace`, takes a registry
domain without a path for `helm registry login`, and no longer runs an
executable path passed to `--post-renderer`. Both repositories are free of those
flags, and `tests/cli-flags` fails the build when one comes back. Commands here
work on Helm 3 and Helm 4 alike: `helm-addons.sh` selects release states with
`--deployed --failed --pending --superseded --uninstalled --uninstalling`
(`HELM_LIST_ALL`), which both versions accept.

## How delivery works

- **ApplicationSets** generate one Application per cluster and component: `tpg-<cluster>-platform`, `-operator`, and `tpg-<cluster>-<instance>`. They carry the labels `tpg.fleet/cluster`, `tpg.fleet/wave` and `tpg.fleet/component`.
- **Helm releases** outside Argo CD: `cert-manager` and `vault-secrets-operator` on every target, `vault` and `vault-secrets-operator` on the hub, and for standalone monitoring `kps` on the hub and `kps` + `tpg-ksm` on targets (`helm list -A`). Every install runs a pre-check first: an existing release of ours is compared (chart version and values) and upgraded, kept or skipped; a compatible foreign cert-manager or Vault Secrets Operator is reused; anything else blocks the run with what it found.
- **No automated sync** on those Applications. Workflows sync them through the Argo CD API as `workflow-bot`, cluster by cluster, canary first.
- **Databases are never pruned.** Postgres resources carry `Prune=false,Delete=false`, and the Postgres CR sets `persistentVolumeClaimPolicy: retain`.
- **Defaults the CRD drops are not declared.** `PostgresBackupLocation` serializes `spec.additionalParameters` and `spec.storage.azure.forcePathStyle` with `omitempty`, so the API server keeps nothing for an empty map or for `false`. An Application that declares them compares a desired object holding the keys with a live object that does not, and stays OutOfSync with a diff no sync can settle. The chart writes `forcePathStyle` only when it is true and `additionalParameters` only when it is non-empty (`charts/tpg-instance/values.yaml`), and the `tpg-instances` ApplicationSet lists those two paths under `ignoreDifferences` for clusters whose operator drops or adds them anyway.
- **High availability needs a data pool that can hold it.** `highAvailability=true` places a primary, a standby and the read replicas on different nodes and zones, so the pre-check refuses a cluster whose data pool does not span 3 zones with 3 Ready nodes. Single-node instances run on any pool shape.
- `tpg-hub-workflows` (templates, scripts, RBAC) and the Azure monitoring Applications use automated sync because they hold no data.

## Secrets

No credential is stored in this repository or in a Kubernetes Secret that someone creates by hand. Three values live in HashiCorp Vault on the hub (`tpg/shared/broadcom-registry`, `github-read`, `github-push`, `backup-storage`), installed and filled by `tpg-aks-infra` (`scripts/steps/35-vault.sh`, `40-hub-secrets.sh`):

| Consumer | How it reads Vault |
|---|---|
| Argo Workflows steps | Vault Agent (injector on the hub) renders `/vault/secrets/*.json` before the step container starts, from the templates in the ConfigMap `tpg-vault-agent` (`workflows/vault-agent/`). Steps that need no credential set `vault.hashicorp.com/agent-inject: "false"` |
| Argo CD repositories | Two `VaultStaticSecret` objects in `argocd` build the repository Secrets for this Git repository and the Broadcom OCI registry |
| Operator and instance namespaces | `charts/tpg-instance/templates/vault-secrets.yaml` and `platform/base/vault-secrets.yaml` create a `VaultStaticSecret` for `regsecret` (image pull) and `backup-storage` (the key the `PostgresBackupLocation` uses), in sync wave -1 so the Secrets exist before the Postgres resources |

The Vault Secrets Operator keeps each Kubernetes Secret in step with Vault, and Argo CD reports a `VaultStaticSecret` as Healthy only once the Secret is synced, so the Postgres sync wave waits for it.

## Workflows

All workflows run in the `argo` namespace as `tpg-workflow`, write per-target results to the ConfigMap `tpg-run-<workflow-name>` (deleted with the workflow), and end with a report printed by the exit handler. When any target is `FAILED` or `TIMEOUT`, the report step fails so the run is flagged in the Argo UI and in the controller metrics.

Mandatory inputs have no default: the first step (`validate`) fails with the list of missing or invalid inputs and the registered cluster names. **[docs/workflow-commands.md](docs/workflow-commands.md) lists every input and several `argo submit` examples per workflow, plus the related `argocd` commands.**

| Workflow | Purpose | Mandatory inputs |
|---|---|---|
| `tpg-day0` | Write the inputs to `fleet.yaml`, pre-check, install cert-manager, deploy operator and instances in waves | `clusters`, `instances`, `highAvailability`, `operatorVersion`, `postgresVersion`, `pushMode` |
| `tpg-upgrade` | Upgrade the operator or Postgres instances in waves | `component`, `targetVersion`, `clusters`, `pushMode`, `instances` (postgres) |
| `tpg-scale-instance` | Set read replicas of one instance | `cluster`, `instance`, `replicas`, `pushMode` |
| `tpg-delete-apps` | Delete instances and/or the operator and its CRDs per cluster | `clusters`, `apps`, `confirm`, `dryRun`, `purgePvcs`, `purgeNamespace`, `pushMode` |
| `tpg-delete-instance` | Guarded delete of one instance | `cluster`, `instance`, `confirm` |
| `tpg-helm-addons` | cert-manager, the Vault Secrets Operator and the standalone monitoring agent Helm releases on targets | `clusters` |
| `tpg-backup` | On-demand backups, full or incremental (CronWorkflows run it on a schedule) | none (`backupType`, `clusters` default) |
| `tpg-backup-retention` | Expire backup chains older than the retention window | none (`clusters`, `retentionDays`, `dryRun` default) |
| `tpg-restore` | Restore an instance: point in time, latest, a named backup, an LSN or a transaction ID, into a new or an existing instance on the same or another cluster | `sourceCluster`, `instance`, `mode` and the recovery point of that mode |
| `tpg-rotate-credential` | Rotate registry, storage or Git credentials | `secretType` |

### Day 0: deploy

```bash
# Dry run: fleet.yaml diff and pre-checks (operator, CRDs, same-named instances, versions)
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct -p dryRun=true --watch

# Deploy: wave 0 canary alone, then later waves in batches of maxParallel (2)
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct --watch
```

| Pre-check status | Meaning |
|---|---|
| `PASSED` | Nothing Tanzu Postgres related on the cluster |
| `MANAGED` | Existing objects are tracked by this Argo CD (safe re-run) |
| `BLOCKED` | Foreign operator, foreign CRDs, same-named instance, missing Postgres version, a data pool that cannot hold an HA instance (`PGDATA_POOL_NOT_HA_CAPABLE`), or unreachable. The cluster is not changed |

### Day 1: upgrade, scale, backup, restore, rotate

```bash
argo submit -n argo --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=all -p pushMode=direct --watch
argo submit -n argo --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-17.7 -p clusters=all -p instances=all -p pushMode=pr --watch
argo submit -n argo --from workflowtemplate/tpg-scale-instance \
  -p cluster=aks-tpg-poc-02 -p instance=orders-db -p replicas=2 -p pushMode=direct --watch
argo submit -n argo --from workflowtemplate/tpg-backup -p backupType=full -p clusters=aks-tpg-poc-01 --watch
argo submit -n argo --from workflowtemplate/tpg-backup-retention -p clusters=all -p dryRun=true --watch
argo submit -n argo --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db -p mode=time \
  -p targetTime=2026-09-15T08:30:00Z --watch
```

- **Upgrade:** minor or major is detected per instance; major needs `allowMajor=true` and pauses for `argo resume` before every batch after the canary. A full backup runs first (`preUpgradeBackup=true`).
- **Backups:** one full backup on Sunday, an incremental one on the other days. Every incremental backup belongs to the chain of the last full backup, so a chain is only ever expired as a whole. If the previous backup is still `Pending` or `Running`, the workflow waits 2 minutes and reports `SKIPPED_IN_PROGRESS`. Instances with `backupSchedule=none` are skipped by the CronWorkflows.
- **Retention:** `tpg-backup-retention` runs daily. It groups the backups of each instance into chains (a full backup and the incrementals that follow it), expires every chain whose newest backup is older than `retentionDays` (35 by default, `backup.retentionDays` per cluster or instance), and always keeps the newest chain, whatever its age. `dryRun=true` reports what it would expire.
- **Restore:** `tpg-restore` restores into a new instance (a one-off clone on the same cluster, or a cluster member added to `clusters/fleet.yaml` and adopted by Argo CD on another cluster) or into an existing one (in place or another instance, which requires `confirm=<instance>` because it overwrites data). For a restore into another namespace or cluster, the workflow creates a read-only copy of the source backup location so `backupSync` lists the source backups there.
- **Credential rotation:** update the value in Vault, then run `tpg-rotate-credential` with `secretType` `broadcom-registry`, `backup-storage` or `git-push`. The workflow verifies that the new value reached every consumer (VaultStaticSecrets, Argo CD repository connection, image pull, backup location, the Blob container).

### Day 2: delete

```bash
# Plan, then run with dryRun=false
argo submit -n argo --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03 -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03 -p dryRun=true -p purgePvcs=false -p purgeNamespace=false -p pushMode=direct --watch
```

Instances leave `clusters/fleet.yaml` (a copy goes to `clusters/deleted/<cluster>/`), the Applications are removed without cascading (`preserveResourcesOnDeletion`), and the workflow deletes the objects in order. With `tpg-operator` it also deletes the operator and the `sql.tanzu.vmware.com` CRDs, refusing while other Postgres instances exist unless `force=true`. The backup repository is never deleted.

## Monitoring

| Option | Apply | Dashboard and alerts |
|---|---|---|
| A: Azure Monitor | `MONITORING_OPTION=azure` in `tpg-aks-infra/env.sh`, `enable_azure_monitor = true` in Terraform | `monitoring/grafana/import-azure-grafana.sh rg-tpgpoc amg-tpgpoc` |
| B: Standalone | `MONITORING_OPTION=standalone`; `tpg-aks-infra` step `addons` installs Helm release `kps` on the hub (creates Secret `monitoring/grafana-admin` first) and `kps` + `tpg-ksm` on targets with the hub remote write URL | Provisioned automatically (dashboard ConfigMap, `grafana.alerting` values) |

Both options scrape the `postgres-exporter` container that the operator runs in every Postgres pod with a `PodMonitor` every 10 seconds (`scrapeTimeout` 8s), and both watch Vault on the hub (`servicemonitor-vault.yaml`, alert `tpg-vault-sealed`: a sealed or unreachable Vault stops every credential from being renewed).

The dashboard **Tanzu Postgres Fleet** shows instances per cluster, healthy and unhealthy instances, ready and desired pod replicas, read replicas, backup and restore counts (succeeded, failed, in progress), backup workflow results, hours since the last successful backup, replication lag, WAL archive failures, connection usage, and active alerts.

Alert definitions live in `monitoring/grafana/generate.py`. After changing them, regenerate the Grafana provisioning values, the API payloads, the PrometheusRule and the dashboard:

```bash
python3 monitoring/grafana/generate.py
```

Email notifications are optional: see `monitoring/grafana/smtp/` (Grafana SMTP for both options) and `monitoring/prometheus/alertmanager-smtp-values.yaml` (Prometheus alerts through Alertmanager). For the standalone hub, pass them with `KPS_HUB_EXTRA_VALUES` to `tpg-aks-infra/scripts/run.sh --only addons`.

## Adding a cluster or an instance

- **Instance:** run `tpg-day0 -p clusters=<cluster> -p instances=<name> ...`. It adds the instance to `clusters/fleet.yaml` and deploys it.
- **Cluster:** create it with `tpg-aks-infra` (`target_cluster_count`) or add a pre-created cluster to `inventory/clusters.yaml` with `wave: 1` or higher, run `tpg-aks-infra/scripts/run.sh` again, then run `tpg-day0 -p clusters=<cluster> ...`. No file or folder is added by hand.

## Static validation

`scripts/validate.sh` runs the same checks used before delivery: `yamllint`, `shellcheck`, `kustomize build`, the `clusters/fleet.yaml` structure, `helm lint` and `helm template` of the instance chart for every `fleet.yaml` instance (with the values the ApplicationSet passes), `kubeconform` (Kubernetes, Argo and Prometheus Operator schemas from the CRDs catalog), and JSON parsing of the dashboard and alert payloads. It ends with `tests/run-all.sh`.

`tests/run-all.sh` runs on its own too, and needs no cluster and no Helm:

- `tests/cli-flags` reads every command in both repositories and fails on a flag the pinned CLI version no longer accepts (`rules.yaml` says which, why and what to write instead). Its fixtures plant one violation per rule, so a rule that stops matching fails the suite. `--against-cli` additionally asks each installed binary for its own flags and reports anything it does not know.
- `tests/helm4` runs `workflows/scripts/helm-addons.sh` against a stub Helm 4 CLI through every pre-check outcome (`DRY_RUN`, `UP_TO_DATE`, `SKIPPED_EXISTS`, `SKIPPED_NEWER`, `REUSED_EXISTING`, `BLOCKED`). The stub rejects `-a` on `helm list` the way Helm 4 does.
- `tpg-aks-infra/tests/verify` drives `scripts/steps/60-verify.sh` against a stubbed cluster and asserts that a missing object is named as missing rather than reported as a wrong field value.

## Items to validate in the lab

The Tanzu for Postgres custom resources have no public JSON schema, so confirm these on the first lab cluster:

| # | Item | How |
|---|---|---|
| V1 | `spec.storage.azure` fields and `backup-storage` keys (`accountName`, `accountKey`) | `kubectl explain postgresbackuplocation.spec.storage.azure`, then one manual backup |
| V2 | Minor upgrades through `PostgresVersionUpgrade`, and whether the operator updates `spec.postgresVersion.name` | Upgrade a test instance by one minor version |
| V3 | Operator upgrade by Argo CD, including CRD updates and instance pod rollout | Run `tpg-upgrade -p component=operator` on the canary |
| V4 | In-place PITR with `pitr.type: time` on an existing instance | Restore a disposable instance with `inPlace=true` |
| V5 | kube-state-metrics timestamp gauges exported as unix seconds | `curl` the `tpg-ksm` metrics endpoint, grep `tanzu_postgres_` |
| V6 | postgres-exporter metric names used in alerts | Port-forward 9187 on a data pod and grep `pg_` |
| V7 | Argo Workflows custom metric names (`argo_workflows_tpg_*_total`) | `curl` the workflow controller metrics Service |
| V8 | `alpine/k8s:1.35.8` and `azure-cli:2.90.0` tags pullable from the hub | `kubectl run` a test pod with each image |
| V9 | Re-creating a deleted instance reattaches retained PVCs | Delete with defaults, then run `tpg-day0` for the instance again |
| V10 | `tpg-delete-apps` with `tpg-operator` removes all 7 `sql.tanzu.vmware.com` CRDs and leftover webhooks | Run on a lab cluster; `kubectl get crd,validatingwebhookconfigurations` |
| V11 | ApplicationSet matrix with `elementsYaml` renders one Application per `fleet.yaml` instance | `argocd appset get tpg-instances`; `argocd app list -l tpg.fleet/component=instance` |
| V12 | Pull request mode with the fine-grained PAT (Pull requests: Read and write) | `tpg-scale-instance -p pushMode=pr -p dryRun=false` on a test instance |
| V13 | `VaultStaticSecret` status conditions of Vault Secrets Operator 1.5.1 (`Ready` and/or `SecretSynced`), which the Argo CD health check reads | `kubectl -n argocd get vaultstaticsecret repo-tpg-fleet -o yaml`; `argocd app get` shows the resource health |
| V14 | Vault Agent injection in the workflow pods: `/vault/secrets/*.json` present and readable | `argo submit --from workflowtemplate/tpg-backup -p dryRun=true`, then `kubectl -n argo exec <pod> -- ls /vault/secrets` |
| V15 | `PostgresBackup.spec.expire` expires the whole chain of a full backup, and `status.phase` afterwards | `tpg-backup-retention -p dryRun=false` on a disposable instance with several chains |
| V16 | `PostgresRestore` with `pitr.type: time`, `latest`, `lsn` and `transaction`, and `sourceBackupLocation.stanzaName` of a copied backup location | `tpg-restore` in each mode on a disposable instance |
| V17 | `backupSync` on the read-only copy of a source backup location lists the source backups in the target namespace | Cross-namespace `tpg-restore`, then `kubectl -n pg-<target> get postgresbackup` |
| V18 | Deleting the copied backup location (label `tpg.fleet/restore-source`) removes only the synced objects | Delete it after a validated restore and check the source namespace |
| V19 | Auto-unseal with the Azure Key Vault key after a `vault-0` restart (`vault_unseal_mode = "azure-keyvault"`) | `kubectl -n vault delete pod vault-0`, then `kubectl -n vault exec vault-0 -- vault status` |
| V20 | Helm version in the tools image, and `helm list` without `-a` | `kubectl -n argo run helmcheck --rm -it --image=alpine/k8s:1.35.8 --restart=Never -- helm version --short` and `... -- helm list -A` |
| V21 | `PostgresBackupLocation` stays Synced: the applied object carries neither `additionalParameters` nor `storage.azure.forcePathStyle`, and the Application reports Synced after two refreshes | `kubectl -n pg-orders-db get postgresbackuplocation orders-db-backup-location -o yaml`; `argocd app get tpg-<cluster>-orders-db --hard-refresh` |
| V22 | `60-verify.sh` names a missing object instead of reporting a wrong value | Delete `storageclass tpg-data-retain` on a lab target, run `scripts/run.sh ... --only verify`, then re-apply it |
| V23 | A step that fails before it records a result reports `UNEXPECTED_ERROR` with the line number, not `UNKNOWN` | Revoke the workflow ServiceAccount's access to `configmap/tpg-run-<workflow>` mid-run, or `kubectl -n argo delete secret kubeconfig-<cluster>` before a `tpg-backup` run; read `kubectl -n argo get configmap tpg-run-<workflow> -o yaml` |
