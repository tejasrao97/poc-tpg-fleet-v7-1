#!/usr/bin/env python3
"""Generate the fleet dashboard, Grafana-managed alert rules and PrometheusRules
from one definition, so the managed and standalone options stay identical.

Usage: python3 monitoring/grafana/generate.py   (run from the repository root)
Requires PyYAML.
"""
import copy
import json
import os
import re
import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MON = os.path.join(ROOT, "monitoring")

# NOTE: argo_workflows_* counter names get a _total suffix in Prometheus exposition.
# Confirm on the hub: curl -s http://<controller-metrics-svc>:8080/metrics | grep tpg_

ALERTS = [
    dict(uid="tpg-instance-not-running", title="Postgres instance not Running",
         expr='1 - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_instance_state{state="Running"})',
         op="gt", threshold=0, for_="5m", severity="critical",
         summary="{{ $labels.cluster }}/{{ $labels.instance_name }} is not in the Running state"),
    dict(uid="tpg-instance-count-dropped", title="Postgres instance count dropped",
         expr='count by (cluster) (tanzu_postgres_instance_state{state="Running"} offset 1h) - count by (cluster) (tanzu_postgres_instance_state{state="Running"})',
         op="gt", threshold=0, for_="0m", severity="warning",
         summary="Fewer Postgres instances on {{ $labels.cluster }} than one hour ago"),
    dict(uid="tpg-replicas-below-desired", title="Postgres pod replicas below desired",
         expr='max by (cluster, namespace, statefulset) (kube_statefulset_replicas{namespace=~"pg-.*"}) - max by (cluster, namespace, statefulset) (kube_statefulset_status_replicas_ready{namespace=~"pg-.*"})',
         op="gt", threshold=0, for_="10m", severity="warning",
         summary="{{ $labels.cluster }}/{{ $labels.statefulset }} has fewer ready pods than desired"),
    dict(uid="tpg-backup-failed", title="Postgres backup failed (24h)",
         expr='count by (cluster, instance_namespace, instance_name) ((tanzu_postgres_backup_phase{phase="Failed"} == 1) and on (cluster, instance_namespace, backup_name) ((time() - tanzu_postgres_backup_created_timestamp) < 86400))',
         op="gt", threshold=0, for_="0m", severity="critical",
         summary="A backup of {{ $labels.cluster }}/{{ $labels.instance_name }} failed in the last 24 hours"),
    dict(uid="tpg-backup-running-long", title="Postgres backup running too long",
         expr='max by (cluster, instance_namespace, instance_name, backup_name) (tanzu_postgres_backup_phase{phase="Running"})',
         op="gt", threshold=0, for_="3h", severity="warning",
         summary="Backup {{ $labels.backup_name }} on {{ $labels.cluster }} has been running for more than 3 hours"),
    dict(uid="tpg-no-recent-backup", title="No successful Postgres backup in 26h",
         expr='(time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600',
         op="gt", threshold=26, for_="0m", severity="critical",
         summary="No successful backup of {{ $labels.cluster }}/{{ $labels.instance_name }} for more than 26 hours"),
    dict(uid="tpg-backup-skipped", title="Postgres backup skipped (previous still running)",
         expr='sum by (cluster, instance_name) (increase(argo_workflows_tpg_backup_result_total{result="SKIPPED_IN_PROGRESS"}[1h]))',
         op="gt", threshold=0, for_="0m", severity="warning",
         summary="The backup workflow skipped {{ $labels.cluster }}/{{ $labels.instance_name }} because the previous backup was still running"),
    dict(uid="tpg-restore-failed", title="Postgres restore failed (24h)",
         expr='count by (cluster, instance_namespace, target_instance) ((tanzu_postgres_restore_phase{phase="Failed"} == 1) and on (cluster, instance_namespace, restore_name) ((time() - tanzu_postgres_restore_created_timestamp) < 86400))',
         op="gt", threshold=0, for_="0m", severity="critical",
         summary="A restore to {{ $labels.cluster }}/{{ $labels.target_instance }} failed in the last 24 hours"),
    dict(uid="tpg-replication-lag", title="Postgres replication lag high",
         expr='max by (cluster, postgres_instance) (pg_replication_lag_seconds)',
         op="gt", threshold=30, for_="5m", severity="warning",
         summary="Replication lag on {{ $labels.cluster }}/{{ $labels.postgres_instance }} is above 30 seconds"),
    dict(uid="tpg-wal-archiving-failing", title="Postgres WAL archiving failing",
         expr='sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count[15m]))',
         op="gt", threshold=0, for_="0m", severity="critical",
         summary="WAL archiving is failing on {{ $labels.cluster }}/{{ $labels.postgres_instance }}; point-in-time recovery is at risk"),
    dict(uid="tpg-connections-high", title="Postgres connections above 80%",
         expr='sum by (cluster, postgres_instance) (pg_stat_activity_count) / max by (cluster, postgres_instance) (pg_settings_max_connections)',
         op="gt", threshold=0.8, for_="10m", severity="warning",
         summary="{{ $labels.cluster }}/{{ $labels.postgres_instance }} uses more than 80% of max_connections"),
    # ---- Delete workflows (tpg-delete-instance, tpg-delete-apps)
    dict(uid="tpg-delete-failed", title="Instance delete failed",
         expr='sum by (cluster, instance_name) (increase(argo_workflows_tpg_delete_result_total{result!="SUCCEEDED"}[1h]))',
         op="gt", threshold=0, for_="0m", severity="warning",
         summary="A delete of {{ $labels.cluster }}/{{ $labels.instance_name }} did not succeed; the instance may be half deleted"),
    # ---- Vault on the hub (unseal mode shamir: sealed after every vault-0 restart)
    dict(uid="tpg-vault-sealed", title="Vault sealed or not reporting",
         expr='(1 - max(vault_core_unsealed)) or absent(vault_core_unsealed)',
         op="gt", threshold=0, for_="2m", severity="critical",
         summary="Vault on the hub is sealed (or its metrics are missing): workflows fail with VAULT_SEALED and secrets are not refreshed. Unseal it with tpg-aks-infra scripts/run.sh ... --only vault-unseal"),
    dict(uid="tpg-exporter-down", title="postgres-exporter target down",
         expr='1 - max by (cluster, postgres_instance) (up{postgres_instance!=""})',
         op="gt", threshold=0, for_="5m", severity="warning",
         summary="postgres-exporter on {{ $labels.cluster }}/{{ $labels.postgres_instance }} cannot be scraped"),
]

FOLDER_UID = "tpg-postgres"
FOLDER_TITLE = "Tanzu Postgres"
GROUP = "tpg-postgres"


def grafana_rule(a, ds_uid):
    return {
        "uid": a["uid"],
        "title": a["title"],
        "condition": "C",
        "data": [
            {"refId": "A", "relativeTimeRange": {"from": 900, "to": 0}, "datasourceUid": ds_uid,
             "model": {"refId": "A", "expr": a["expr"], "instant": True, "range": False,
                       "intervalMs": 60000, "maxDataPoints": 43200}},
            {"refId": "B", "datasourceUid": "__expr__",
             "model": {"refId": "B", "type": "reduce", "expression": "A", "reducer": "last",
                       "settings": {"mode": "dropNN"}}},
            {"refId": "C", "datasourceUid": "__expr__",
             "model": {"refId": "C", "type": "threshold", "expression": "B",
                       "conditions": [{"evaluator": {"type": a["op"], "params": [a["threshold"]]}}]}},
        ],
        "noDataState": "OK",
        "execErrState": "Error",
        "for": a["for_"],
        "labels": {"severity": a["severity"]},
        "annotations": {"summary": a["summary"]},
    }


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class Dumper(yaml.SafeDumper):
    pass


def _str(d, s):
    return d.represent_scalar("tag:yaml.org,2002:str", s, style='"' if ("{{" in s or ":" in s) else None)


Dumper.add_representer(str, _str)


# ---- 1. Grafana provisioning (standalone hub, kube-prometheus-stack grafana.alerting)
def helm_escape(rule):
    # The Grafana chart renders grafana.alerting through Helm tpl, so Grafana
    # template expressions must be escaped to survive rendering.
    r = copy.deepcopy(rule)
    r["annotations"]["summary"] = re.sub(r"\{\{(.*?)\}\}", lambda m: '{{ "{{" }}' + m.group(1) + '{{ "}}" }}',
                                         r["annotations"]["summary"])
    return r


prov = {"apiVersion": 1, "groups": [{"orgId": 1, "name": GROUP, "folder": FOLDER_TITLE, "interval": "1m",
                                     "rules": [helm_escape(grafana_rule(a, "prometheus")) for a in ALERTS]}]}
values = {"grafana": {"alerting": {"tpg-alert-rules.yaml": prov}}}
write(os.path.join(MON, "grafana/alerts/grafana-alerting-values.yaml"),
      "# GENERATED by monitoring/grafana/generate.py - do not edit by hand.\n"
      "# Grafana-managed alert rules for the standalone hub (kube-prometheus-stack values).\n"
      + yaml.dump(values, Dumper=Dumper, sort_keys=False, width=1000))

# ---- 2. Grafana provisioning API payloads (Azure Managed Grafana)
for a in ALERTS:
    r = grafana_rule(a, "${DATASOURCE_UID}")
    r.update({"folderUID": FOLDER_UID, "ruleGroup": GROUP, "orgID": 1})
    write(os.path.join(MON, "grafana/alerts/api", a["uid"] + ".json"), json.dumps(r, indent=2) + "\n")

# ---- 3. PrometheusRule (standalone Prometheus -> Alertmanager email)
ops = {"gt": ">", "lt": "<"}
prom_rules = []
for a in ALERTS:
    name = "".join(w.capitalize() for w in a["uid"].replace("tpg-", "").split("-"))
    rule = {"alert": "TanzuPostgres" + name,
            "expr": "(%s) %s %s" % (a["expr"], ops[a["op"]], a["threshold"]),
            "labels": {"severity": a["severity"]},
            "annotations": {"summary": a["summary"]}}
    if a["for_"] != "0m":
        rule["for"] = a["for_"]
    prom_rules.append(rule)
pr = {"apiVersion": "monitoring.coreos.com/v1", "kind": "PrometheusRule",
      "metadata": {"name": "tpg-rules", "namespace": "monitoring", "labels": {"release": "kps"}},
      "spec": {"groups": [{"name": "tanzu-postgres", "rules": prom_rules}]}}
write(os.path.join(MON, "standalone/hub/prometheusrule-tpg.yaml"),
      "# GENERATED by monitoring/grafana/generate.py - do not edit by hand.\n"
      + yaml.dump(pr, Dumper=Dumper, sort_keys=False, width=1000))

# ---- 4. Dashboard
DS = {"type": "prometheus", "uid": "${datasource}"}
panels = []
pid = [0]


def panel(title, ptype, targets, x, y, w, h, extra=None):
    pid[0] += 1
    p = {"id": pid[0], "title": title, "type": ptype, "datasource": DS,
         "gridPos": {"x": x, "y": y, "w": w, "h": h},
         "targets": [dict(refId=chr(65 + i), datasource=DS, expr=e, legendFormat=l,
                          instant=(ptype in ("stat", "table", "bargauge")), range=(ptype in ("timeseries", "barchart")))
                     for i, (e, l) in enumerate(targets)]}
    if extra:
        p.update(extra)
    panels.append(p)


def row(title, y):
    pid[0] += 1
    panels.append({"id": pid[0], "type": "row", "title": title, "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})


C = '{cluster=~"$cluster"}'
thr_red = {"fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [
    {"color": "green", "value": None}, {"color": "red", "value": 1}]}}, "overrides": []}}

row("Fleet overview", 0)
panel("Postgres instances per AKS cluster", "bargauge",
      [('count by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"})', "{{cluster}}")], 0, 1, 8, 7,
      {"options": {"orientation": "horizontal", "displayMode": "gradient", "reduceOptions": {"calcs": ["lastNotNull"]}}})
panel("Healthy instances", "stat",
      [('sum by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"})', "{{cluster}}")], 8, 1, 8, 7,
      {"fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "green"}}, "overrides": []}})
panel("Unhealthy instances", "stat",
      [('count by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"} == 0) or on (cluster) (count by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"}) * 0)', "{{cluster}}")],
      16, 1, 8, 7, thr_red)
panel("Instance state", "table",
      [('tanzu_postgres_instance_state{cluster=~"$cluster"} == 1', "")], 0, 8, 24, 8,
      {"transformations": [{"id": "labelsToFields", "options": {"mode": "columns"}},
                           {"id": "organize", "options": {"excludeByName": {"Time": True, "Value": True, "__name__": True, "job": True, "instance": True, "pod": True, "service": True, "endpoint": True, "container": True, "customresource_group": True, "customresource_kind": True, "customresource_version": True}}}]})
row("Replicas", 16)
panel("Pod replicas: ready vs desired", "table",
      [('max by (cluster, namespace, statefulset) (kube_statefulset_status_replicas_ready{namespace=~"pg-.*",cluster=~"$cluster"})', "ready"),
       ('max by (cluster, namespace, statefulset) (kube_statefulset_replicas{namespace=~"pg-.*",cluster=~"$cluster"})', "desired")], 0, 17, 14, 8,
      {"transformations": [{"id": "merge", "options": {}},
                           {"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value #A": "ready", "Value #B": "desired"}}}]})
panel("Desired read replicas", "table",
      [('max by (cluster, instance_namespace, instance_name) (tanzu_postgres_instance_read_replicas{cluster=~"$cluster"})', "")], 14, 17, 10, 8,
      {"transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "readReplicas"}}}]})
row("Backup and restore", 25)
panel("Backups succeeded", "stat", [('sum by (cluster) (tanzu_postgres_backup_phase{phase="Succeeded",cluster=~"$cluster"})', "{{cluster}}")], 0, 26, 8, 6,
      {"fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "green"}}, "overrides": []}})
panel("Backups failed", "stat", [('sum by (cluster) (tanzu_postgres_backup_phase{phase="Failed",cluster=~"$cluster"})', "{{cluster}}")], 8, 26, 8, 6, thr_red)
panel("Backups in progress", "stat", [('sum by (cluster) (tanzu_postgres_backup_phase{phase=~"Pending|Running",cluster=~"$cluster"})', "{{cluster}}")], 16, 26, 8, 6,
      {"fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "blue"}}, "overrides": []}})
panel("Restores succeeded", "stat", [('sum by (cluster) (tanzu_postgres_restore_phase{phase="Succeeded",cluster=~"$cluster"})', "{{cluster}}")], 0, 32, 8, 6,
      {"fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "green"}}, "overrides": []}})
panel("Restores failed", "stat", [('sum by (cluster) (tanzu_postgres_restore_phase{phase="Failed",cluster=~"$cluster"})', "{{cluster}}")], 8, 32, 8, 6, thr_red)
panel("Restores in progress", "stat", [('sum by (cluster) (tanzu_postgres_restore_phase{phase!~"Succeeded|Failed",cluster=~"$cluster"})', "{{cluster}}")], 16, 32, 8, 6,
      {"fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "blue"}}, "overrides": []}})
panel("Backup workflow results (24h)", "table",
      [('sum by (cluster, instance_name, backup_type, result) (increase(argo_workflows_tpg_backup_result_total[24h]))', "")], 0, 38, 12, 8,
      {"transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "runs"}}}]})
panel("Hours since last successful backup", "table",
      [('(time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp{cluster=~"$cluster"} and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600', "")], 12, 38, 12, 8,
      {"fieldConfig": {"defaults": {"decimals": 1, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 26}]},
                                    "custom": {"cellOptions": {"type": "color-background"}}}, "overrides": []},
       "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "hours"}}}]})
row("Database", 46)
panel("Replication lag (seconds)", "timeseries", [('max by (cluster, postgres_instance) (pg_replication_lag_seconds{cluster=~"$cluster"})', "{{cluster}}/{{postgres_instance}}")], 0, 47, 12, 8)
panel("WAL archive failures (15m)", "timeseries", [('sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count{cluster=~"$cluster"}[15m]))', "{{cluster}}/{{postgres_instance}}")], 12, 47, 12, 8)
panel("Connections used (%)", "timeseries", [('100 * sum by (cluster, postgres_instance) (pg_stat_activity_count{cluster=~"$cluster"}) / max by (cluster, postgres_instance) (pg_settings_max_connections{cluster=~"$cluster"})', "{{cluster}}/{{postgres_instance}}")], 0, 55, 12, 8)
row("Delete", 63)
panel("Instance deletes (7d)", "table",
      [('sum by (cluster, instance_name, purge_pvcs, result) (increase(argo_workflows_tpg_delete_result_total[7d]))', "")], 0, 64, 12, 8,
      {"transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "runs"}}}]})
pid[0] += 1
panels.append({"id": pid[0], "title": "Active alerts", "type": "alertlist", "gridPos": {"x": 12, "y": 55, "w": 12, "h": 8},
               "options": {"viewMode": "list", "groupMode": "default", "maxItems": 50, "sortOrder": 1,
                           "stateFilter": {"firing": True, "pending": True, "noData": False, "normal": False, "error": True},
                           "folder": {"uid": FOLDER_UID, "title": FOLDER_TITLE}, "showInstances": True}})
dashboard = {
    "uid": "tpg-fleet", "title": "Tanzu Postgres Fleet", "tags": ["tanzu-postgres", "tpg"],
    "timezone": "utc", "schemaVersion": 39, "version": 1, "refresh": "1m",
    "time": {"from": "now-24h", "to": "now"},
    "templating": {"list": [
        {"name": "datasource", "type": "datasource", "query": "prometheus", "label": "Data source", "current": {}},
        {"name": "cluster", "type": "query", "label": "Cluster", "datasource": DS,
         "query": {"query": "label_values(tanzu_postgres_instance_state, cluster)", "refId": "cluster"},
         "definition": "label_values(tanzu_postgres_instance_state, cluster)",
         "includeAll": True, "multi": True, "allValue": ".*", "refresh": 2, "current": {}}]},
    "panels": panels,
}
write(os.path.join(MON, "standalone/hub/dashboards/tpg-fleet.json"), json.dumps(dashboard, indent=2) + "\n")
print("generated %d alert rules and dashboard with %d panels" % (len(ALERTS), len(panels)))
