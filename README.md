# docker-error-watcher

Lightweight Docker log error watcher that auto-creates GitHub Issues. Zero dependencies beyond `bash` and `gh` CLI.

## What it does

1. Discovers all running Docker containers automatically
2. Scans their logs for errors (last 5 minutes)
3. Deduplicates by error content hash
4. Creates GitHub Issues with full context (stack trace, route, log line)
5. If the issue already exists, adds a comment instead of duplicating
6. Respects cooldowns and flood limits

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

## License

MIT
