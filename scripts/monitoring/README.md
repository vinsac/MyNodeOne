# Monitoring configuration

Settings that `bootstrap-control-plane.sh` applies to kube-prometheus-stack. To apply them to a running cluster, run:

```bash
sudo scripts/monitoring/apply-monitoring-config.sh
```

| File | What it does |
| --- | --- |
| `kube-prometheus-stack-values.yaml` | Sets the Prometheus size limit, turns off rules that always fire on k3s, and adds the node-exporter directory for backup metrics |
| `longhorn-servicemonitor.yaml` | Makes Prometheus scrape Longhorn |
| `prometheus-alerts/` | Alerts for disk space, Longhorn health, the LLM gateway and backup age |
| `alertmanager-values.example.yaml` | Example alert destination, not read by anything |
| `apply-monitoring-config.sh` | Applies all of the above to a running cluster |

## Sending alerts somewhere

By default, alerts are only visible in Prometheus and Alertmanager. To send them somewhere, copy the example to `/etc/mynodeone/alertmanager-values.yaml`, keep it root-only, fill in your destination, and run the apply script. See the comments in the example file. You can also set `ALERTMANAGER_VALUES_FILE` to use a different path.

## Backup metrics

`scripts/backup/backup-control-plane-state.sh` writes its last-success time to `/var/lib/mynodeone/metrics`, and node-exporter reads that directory. Other host-level jobs can publish metrics the same way: write a `*.prom` file there with a temporary name, then rename it.
