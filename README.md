# docker-error-watcher

Lightweight Docker log error watcher that auto-creates GitHub Issues. Zero dependencies beyond `bash` and `gh` CLI.

## What it does

1. Discovers all running Docker containers automatically
2. Scans their logs for errors (last 5 minutes)
3. Deduplicates by error content hash
4. Creates GitHub Issues with full context (stack trace, route, log line)
5. If the issue already exists, adds a comment instead of duplicating
6. Respects cooldowns and flood limits
7. **Emits per-run metrics** to `~/.docker-watcher/metrics.jsonl` (counts per container/route)
8. **Optional rate-spike alerts**: opens a distinct GitHub Issue when a single (container, route) exceeds N errors in the scan window
9. **Optional webhook**: POSTs the per-run summary to any HTTP endpoint (Slack Incoming Webhook, Grafana Loki, generic sink)

## Requirements

- `docker` (with permission to read logs)
- `gh` (GitHub CLI, authenticated via `gh auth login`)
- `bash`

That's it. No Node.js, no Python, no databases, no external services.

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/bot202102/docker-error-watcher.git
cd docker-error-watcher
chmod +x docker-error-watcher.sh

# Create your repo mapping
cp repos.conf.example ~/.docker-watcher/repos.conf
```

### 2. Map containers to repos

Edit `~/.docker-watcher/repos.conf`:

```conf
# container-pattern=owner/repo
myapp-*=myorg/myapp-repo
redis-*=myorg/infra
postgres-*=myorg/infra
```

### 3. Create the GitHub label

For each repo you monitor:

```bash
gh label create "auto-reported" --repo myorg/myapp --color "d93f0b" --description "Auto-created by docker-error-watcher"
```

### 4. Add to cron

```bash
# Run every 5 minutes
crontab -e
*/5 * * * * /path/to/docker-error-watcher.sh >> ~/.docker-watcher/watcher.log 2>&1
```

## Configuration

All settings via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `WATCHER_STATE_DIR` | `~/.docker-watcher` | Where to store dedup state |
| `WATCHER_COOLDOWN` | `3600` | Seconds between reports of same error |
| `WATCHER_MAX_ISSUES` | `5` | Max issues created per run (anti-flood) |
| `WATCHER_LOG_WINDOW` | `5m` | How far back to scan logs |
| `WATCHER_DEFAULT_REPO` | (empty) | Fallback repo for unknown containers |
| `WATCHER_CONFIG` | `~/.docker-watcher/repos.conf` | Path to repo mapping file |
| `WATCHER_EXTRA_EXCLUDE_PATTERN` | (empty) | Extra pipe-separated regex fragments appended to the built-in false-positive filter |
| `WATCHER_METRICS_FILE` | `~/.docker-watcher/metrics.jsonl` | JSONL log of per-run aggregates |
| `WATCHER_METRICS_RETENTION_DAYS` | `30` | Rotate metrics file after N days |
| `WATCHER_RATE_THRESHOLD` | `0` (off) | If >0, open a rate-spike Issue when one (container, route) hits ≥N errors in `WATCHER_LOG_WINDOW` |
| `WATCHER_WEBHOOK_URL` | (empty) | If set, POST per-run summary JSON here |
| `WATCHER_HOSTNAME` | `$(hostname)` | Host label emitted in metrics + issues |

## Metrics + alerting (v2)

### Per-run metrics file

Every run appends one JSONL row per unique (container, route) seen in the log window:

```json
{"ts":"2026-04-17T10:13:00Z","host":"vmi2821414","container":"flockos-app","route":"/api/dashboard/pastor","count":47,"window":"5m","sample":"Unhandled API error: ..."}
```

Consumers:
- `tail -F ~/.docker-watcher/metrics.jsonl | jq ...` for live on-call view
- Prometheus [node_exporter textfile collector](https://github.com/prometheus/node_exporter#textfile-collector) can scrape this
- Push to Loki/Elasticsearch via Filebeat/Promtail

### Rate-spike alerting

When `WATCHER_RATE_THRESHOLD=N` is set, an extra GitHub Issue is opened as soon as any single (container, route) sees ≥N errors within one scan window. Deduped once per day per (container, route) via a spike-state file, so a sustained incident produces one issue/day instead of one-per-run.

The title/labels differ from the per-error issues (`[auto] rate-spike …`, label `rate-spike`), so ops can triage separately from individual stack traces.

Typical setup: `WATCHER_RATE_THRESHOLD=20` + `WATCHER_LOG_WINDOW=5m` catches “100% of requests failing on this endpoint” within minutes.

### Webhook

`WATCHER_WEBHOOK_URL=https://example.com/hook` posts the run summary as JSON. Payload shape:

```json
{
  "ts": "2026-04-17T10:13:00Z",
  "host": "vmi2821414",
  "window": "5m",
  "events": [ { "container":"...", "route":"...", "count": 47, ... }, ... ]
}
```

Compatible with Slack Incoming Webhooks if you wrap the events into a Slack message body, or with any generic HTTP sink (Grafana OnCall, PagerDuty Events v2, custom Lambda).

## How deduplication works

```
Error message + container name
         ↓
    MD5 hash → state file (~/.docker-watcher/<hash>)
         ↓
    Timestamp of last report
         ↓
    If < COOLDOWN seconds → skip
    If open issue exists  → add comment
    Otherwise             → create new issue
```

State files older than 7 days are auto-cleaned.

## Example issue created

```
Title: [auto] myapp-web: Failed query: relation "users" does not exist

Body:
| Field      | Value                          |
|------------|--------------------------------|
| Container  | myapp-web                      |
| Host       | prod-server-1                  |
| Date       | 2026-03-07 04:30 UTC           |
| Route      | /api/auth/sign-in/email        |

Error message: Failed query: relation "users" does not exist
Stack trace: ...
```

## Filtering

### What it catches
- JSON structured logs with `"level":"error"`
- Lines containing `ERROR`, `[ERROR]`, `FATAL`, `PANIC`, `Unhandled`
- Uncaught exceptions and unhandled rejections

### What it ignores (false positives)
- Healthcheck commands (`pg_isready`, `redis-cli`)
- PostgreSQL WAL recovery messages
- Permission errors (usually auth-level, not crashes)

Customize patterns in the script: `ERROR_PATTERN` and `EXCLUDE_PATTERN`.

For host-specific benign noise, prefer an environment override instead of
editing the script:

```bash
WATCHER_EXTRA_EXCLUDE_PATTERN='known benign message|another harmless retry'
```

Built-in false positives include resilient Redis broker retry lines such as
`Redis broker listen interrupted; retrying`, which indicate the worker retry
path rather than a product crash.

## License

MIT
