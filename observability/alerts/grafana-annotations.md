# Grafana Alert Annotations

This file explains how to wire Alertmanager webhooks to Grafana annotations so alerts show up on dashboard panels.

## Architecture

```
Prometheus → Alertmanager → webhook → alertmanager-telegram-bot
                                   ↓
                                   (Telegram notification)
                                   
                             (also possible:)
                                   
                                   → grafana-annotation-call
                                   ↓
                                   Grafana annotations API
                                   ↓
                                   Dashboard panels show alert markers
```

## How it works

Grafana's "annotations" feature lets you overlay events on dashboard time-series panels. The annotations can come from:
1. Grafana's own alerting engine (built-in)
2. Alertmanager webhooks (via Grafana's annotations API)
3. Other sources via the HTTP API

For our homelab, we want **option 2**: Alertmanager fires an alert → it gets sent to Grafana's annotation API → dashboards show the alert as a vertical line.

## Setup (when you have time, not blocking)

The current setup uses Alertmanager → Telegram bot directly. Adding Grafana annotations is a nice-to-have that requires:

1. **A webhook receiver in Alertmanager** that POSTs to Grafana's annotation API
2. **Grafana API key** with annotation write permission
3. **An Alertmanager config patch** (separate from the current Telegram config)

## Simpler alternative: Grafana built-in alerts

Since we enabled `grafana.alerting.enabled: true`, Grafana can show annotations from its OWN alerts automatically. The ConfigMap in `observability/alerts/pod-crashlooping.yaml` creates Grafana alerts that will show on dashboards as annotations.

No additional webhook setup needed for this.

## Even simpler: dashboard-level annotations

You can add annotations directly to specific dashboards by editing them in the Grafana UI. This is manual but doesn't require any infrastructure changes.

## When to revisit

If you find yourself wanting:
- All Alertmanager alerts visible on dashboards (not just Grafana's own alerts)
- Cross-system annotations (Loki events, deployment events, etc.)

Then come back to this file and follow the setup steps. For now, the Grafana built-in alerting with automatic annotations is sufficient.
