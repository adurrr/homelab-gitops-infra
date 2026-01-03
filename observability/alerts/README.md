# Grafana Managed Alerting

Grafana Unified Alerting is enabled in the prometheus app values. Contact points and alert rules are provisioned via Kubernetes ConfigMaps with special labels.

## Architecture

- **Grafana** runs the unified alerting engine (separate from Prometheus alerting)
- Contact points and rules are provisioned via the [grafana-operator-style API](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources-file-provisioning/)
- ConfigMaps in the `monitoring` namespace with the right labels get auto-loaded

## Contact Points

Contact points are defined as Kubernetes Secrets (because they contain the Telegram bot token) or ConfigMaps (for simple ones).

### Telegram contact point

Create a SealedSecret or plain Secret named `grafana-contact-point-telegram`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: grafana-contact-point-telegram
  namespace: monitoring
  labels:
    grafana_alert: "1"
type: Opaque
stringData:
  # The full Grafana contact-point YAML
  contact-point.yaml: |
    apiVersion: 1
    contactPoints:
      - orgId: 1
        name: Telegram
        receivers:
          - name: Telegram
            settings:
              url: http://alertmanager-telegram-bot.monitoring.svc.cluster.local:8080/alert
            type: webhook
```

The `alertmanager-telegram-bot` is the bridge service we already built (see `apps/alertmanager-telegram-bot/`).

## Alert Rules

Alert rules are defined as ConfigMaps with the `grafana_alert` label.

### Example: "Pod CrashLooping for >5 min" rule

Create `observability/alerts/pod-crashlooping.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-alert-pod-crashlooping
  namespace: monitoring
  labels:
    grafana_alert: "1"
data:
  alert.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: homelab-pod-health
        folder: Homelab
        interval: 1m
        rules:
          - uid: pod-crashlooping-5m
            title: Pod CrashLooping >5m
            condition: C
            data:
              - refId: A
                relativeTimeRange:
                  from: 300
                  to: 0
                datasourceUid: prometheus
                model:
                  expr: sum by (namespace, pod) (kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}) > 0
              - refId: C
                datasourceUid: __expr__
                model:
                  type: threshold
                  expression: A
                  conditions:
                    - evaluator:
                        type: gt
                        params: [0]
                      operator: { type: and }
                      query: { params: [A] }
                      reducer: { type: last }
                      type: query
            noDataState: NoData
            execErrState: Error
            for: 5m
            annotations:
              summary: 'Pod {{ $labels.pod }} in {{ $labels.namespace }} is crashlooping'
            labels:
              severity: critical
              source: grafana
```

After applying:

```bash
kubectl apply -f observability/alerts/pod-crashlooping.yaml
```

Grafana will pick it up within a minute and start evaluating.

## Webhook URL for Alertmanager (for cross-system notifications)

If you want Grafana to also notify via Alertmanager (and thus through the existing Telegram bridge), set the Grafana contact point URL to:

```
http://alertmanager-operated.monitoring.svc.cluster.local:9093/api/v2/alerts
```

But the current setup is simpler: Grafana calls the Telegram bot directly via webhook.
