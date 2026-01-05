# ntfy: Self-Hosted Push Notifications

> **Name:** [docs.ntfy.sh](https://docs.ntfy.sh/) · **GitHub:** [binwiederhier/ntfy](https://github.com/binwiederhier/ntfy) · **Docker:** [binwiederhier/ntfy](https://hub.docker.com/r/binwiederhier/ntfy)
> **CNCF Status:** N/A

## Overview

**ntfy** (pronounced "notify") is a simple HTTP-based pub/sub notification service. It lets you send push notifications to your phone via HTTP PUT/POST. Topics are created on the fly — just publish to a topic and any subscriber receives it. It is a single Go binary with zero external dependencies.

In this project, ntfy replaces the RocketChat placeholder used in Alertmanager for alert notifications. When Prometheus fires an alert, Alertmanager sends a webhook POST to ntfy, which pushes the notification to subscribed mobile devices.

## How It Works

```
                  ┌─────────────────────────────────────┐
                  │          Alertmanager                │
                  │                                      │
                  │  ┌──────────────────────────────┐   │
                  │  │  Receiver: "ntfy"            │   │
                  │  │  webhook_configs:             │   │
                  │  │    url: "http://ntfy.ntfy.    │   │
                  │  │      svc.cluster.local/       │   │
                  │  │      prometheus-alerts"       │   │
                  │  └─────────────┬────────────────┘   │
                  └────────────────┼─────────────────────┘
                                   │
                                   │ HTTP POST
                                   │ "🔥 HighCPUUsage
                                   │  Node node-1 > 90%"
                                   ▼
                  ┌─────────────────────────────────────┐
                  │          ntfy Server                 │
                  │          (Go binary)                 │
                  │                                      │
                  │  ┌──────────────────────────────┐   │
                  │  │  Topic Queue                  │   │
                  │  │  /prometheus-alerts           │   │
                  │  │  ┌──────┬──────┬──────┐      │   │
                  │  │  │ msg1 │ msg2 │ msg3 │ ...  │   │
                  │  │  └──────┴──────┴──────┘      │   │
                  │  └──────────────────────────────┘   │
                  └──────────────────┬──────────────────┘
                                     │
                    ┌────────────────┼────────────────┐
                    │                │                 │
                    ▼                ▼                 ▼
              ┌──────────┐    ┌──────────┐    ┌──────────────┐
              │ iOS App  │    │ Android  │    │ Web/Desktop  │
              │ (native) │    │ App      │    │ (subscribe   │
              │          │    │ (native) │    │  via curl/ws)│
              │ Push     │    │ Push     │    │              │
              │ notif.   │    │ notif.   │    │ long-polling │
              └──────────┘    └──────────┘    └──────────────┘
```

### The Protocol (Dead Simple)

```bash
# Publish a notification
curl -d "Backup complete on node-1" ntfy.homelab.local/backups

# With priority, tags, and a click action
curl -H "Title: Backup Status" \
     -H "Priority: high" \
     -H "Tags: white_check_mark" \
     -H "Click: https://grafana.homelab.local" \
     -d "Backup completed successfully" \
     ntfy.homelab.local/backups

# Subscribe (long-polling)
curl -s ntfy.homelab.local/backups/json
```

## Key Features

### 1. Zero-Config Topics

Publish to any topic name and it auto-creates. No pre-registration, no database setup. Topic names are just URL path segments: `ntfy.homelab.local/my-topic`.

### 2. Native Mobile Apps

| Platform | App | Push Delivery |
|----------|-----|---------------|
| iOS | [ntfy App](https://apps.apple.com/us/app/ntfy/id1625396347) | APNs via UnifiedPush |
| Android | [ntfy App](https://play.google.com/store/apps/details?id=io.heckel.ntfy) | FCM via UnifiedPush |

Both support **UnifiedPush** — a standard that works with self-hosted servers without relying on Google/Apple push services exclusively.

### 3. Access Control

ntfy supports per-topic access tokens with tiered permissions:

| Permission | Capabilities |
|-----------|-------------|
| `read-only` | Subscribe to topic, read messages |
| `read-write` | Publish and subscribe |
| `deny-all` | No access (default for private instances) |

### 4. Rich Notifications

- **Priority levels**: `min`, `low`, `default`, `high`, `max` (drives phone vibration + alert behavior)
- **Tags/Emoji**: Prepend emoji via tags like `warning`, `fire`, `white_check_mark`
- **Click actions**: Open a URL when the user taps the notification
- **Attachments**: Inline images (up to ~1MB recommended for mobile)
- **Scheduled delivery**: Publish with a delay timestamp

### 5. Self-Hosted Simplicity

Single Go binary, no database, no external dependencies. Persistence is optional (enabled in this project via the `cache-file`).

## Best Practices

- **Set `NTFY_BEHIND_PROXY: true`** when running behind Traefik — this enables WebSocket support and correct client IP detection.
- **Set `NTFY_AUTH_DEFAULT_ACCESS: deny-all`** for private instances — explicit topic access tokens for every consumer.
- **Use per-topic access tokens** rather than a single global admin token. Granular revocation on compromise.
- **Reserve attachments for images** — each attachment is stored on the server filesystem. Don't use ntfy as a generic file store.
- **ARM64 compatibility**: The `binwiederhier/ntfy` image is multi-arch with native `linux/arm64` support.
- **Resource budget**: ~50MB RAM, ~10m CPU — negligible, runs comfortably on a Raspberry Pi.

## Security Considerations

| Concern | Mitigation |
|---------|-----------|
| **Unauthorized subscriptions** | Set `NTFY_AUTH_DEFAULT_ACCESS: deny-all`; only issue tokens to known subscribers |
| **Sign-up abuse** | Set `NTFY_ENABLE_SIGNUP: false` — admin creates topics and tokens manually |
| **Cleartext traffic** | Terminate TLS at Traefik; ntfy runs HTTP internally behind the proxy |
| **Public internet exposure** | Restrict to LAN/VPN if possible. No operational need for public access in homelab |
| **Token rotation** | Rotate access tokens periodically (e.g., every 6 months) |
| **Attachment storage** | Each attachment occupies server disk. Set `ntfy-attachment-total-size-limit` to cap usage |
| **Logging of messages** | ntfy logs message metadata by default. Check `NTFY_LOG_LEVEL` if message content privacy is a concern |

## Configuration in This Project

```yaml
# platform/ntfy/values.yaml (key settings)
image:
  repository: binwiederhier/ntfy
  tag: "latest"                              # Pinned to a specific SHA in production

resources:
  requests: { cpu: 10m, memory: 32Mi }
  limits:   { cpu: 100m, memory: 64Mi }

persistence:
  enabled: true
  size: 1Gi
  storageClass: local-path                   # Persist message cache + attachments

ingress:
  enabled: true
  className: traefik
  hosts:
    - host: ntfy.homelab.local
  tls:
    - hosts: [ntfy.homelab.local]
      secretName: ntfy-tls

env:
  NTFY_BASE_URL: "https://ntfy.homelab.local"
  NTFY_BEHIND_PROXY: "true"
  NTFY_AUTH_DEFAULT_ACCESS: "deny-all"
  NTFY_ENABLE_SIGNUP: "false"
```

### Alertmanager Integration

```yaml
# observability/kube-prometheus-stack/alertmanager-config.yaml
receivers:
  - name: 'ntfy'
    webhook_configs:
      - url: "http://ntfy.ntfy.svc.cluster.local/prometheus-alerts"
        send_resolved: true
        http_config:
          headers:
            Authorization: "Bearer <ntfy-access-token>"   # Per-topic token

route:
  receiver: 'ntfy'
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
```

### Quick Test

```bash
# From any pod in the cluster:
kubectl exec -it <pod> -- curl -d \
  "Test alert from Kubernetes cluster" \
  http://ntfy.ntfy.svc.cluster.local/prometheus-alerts
```

## Official References

- [ntfy Documentation](https://docs.ntfy.sh/)
- [ntfy Install Guide](https://docs.ntfy.sh/install/)
- [ntfy Alertmanager Integration](https://docs.ntfy.sh/integrations/#alertmanager)
- [ntfy GitHub](https://github.com/binwiederhier/ntfy)
- [ntfy Access Control](https://docs.ntfy.sh/config/#access-control)
- [UnifiedPush Standard](https://unifiedpush.org/)
