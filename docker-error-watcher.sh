#!/bin/bash
# ─── Docker Error Watcher → GitHub Issues ───
# Monitors ALL running Docker containers for errors in logs,
# deduplicates them, and auto-creates GitHub Issues.
#
# Features:
#   - Auto-discovers all running containers
#   - Maps containers to GitHub repos by name prefix
#   - Deduplicates errors by (container, route, error) hash
#   - Cooldown per error (default 1 hour)
#   - Flood protection (max issues per run)
#   - Adds comments to existing open issues instead of creating duplicates
#   - Filters out common false positives (healthchecks, WAL recovery, etc.)
#   - Cleans up old state files automatically
#   - Heartbeat log line per run for observability
#
# Requirements: docker, gh (GitHub CLI, authenticated). Optional: jq.
# Usage: Run via cron every 5 minutes
#   */5 * * * * /path/to/docker-error-watcher.sh >> /path/to/watcher.log 2>&1

# ─── Configuration ───
STATE_DIR="${WATCHER_STATE_DIR:-$HOME/.docker-watcher}"
COOLDOWN="${WATCHER_COOLDOWN:-3600}"          # Seconds between reports of same error
MAX_ISSUES_PER_RUN="${WATCHER_MAX_ISSUES:-5}" # Anti-flood: max issues per execution
LOG_WINDOW="${WATCHER_LOG_WINDOW:-5m}"        # How far back to check logs
DEFAULT_REPO="${WATCHER_DEFAULT_REPO:-}"      # Fallback repo (leave empty to skip unknown containers)

mkdir -p "$STATE_DIR"

ts() { date -u '+%Y-%m-%d %H:%M UTC'; }

# ─── Preflight checks ───
# Without these the script previously ran silently for weeks producing 0
# issues and 0 log entries when gh was missing or auth had expired.
if ! command -v docker >/dev/null 2>&1; then
    echo "[$(ts)] FATAL: docker not installed or not in PATH" >&2
    exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "[$(ts)] FATAL: gh CLI not installed. Install: https://cli.github.com" >&2
    exit 2
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "[$(ts)] FATAL: gh CLI not authenticated. Run: gh auth login" >&2
    exit 2
fi

HAS_JQ=0
command -v jq >/dev/null 2>&1 && HAS_JQ=1

# ─── Container → Repo mapping ───
# Maps container name patterns to GitHub repos.
# Example: container "myapp-web" matches "myapp-*" → "myorg/myapp"
get_repo() {
    local container="$1"

    local config_file="${WATCHER_CONFIG:-$HOME/.docker-watcher/repos.conf}"
    if [ -f "$config_file" ]; then
        while IFS='=' read -r pattern repo; do
            [[ "$pattern" =~ ^#.*$ ]] && continue
            [ -z "$pattern" ] && continue
            if [[ "$container" == $pattern ]]; then
                echo "$repo"
                return
            fi
        done < "$config_file"
    fi

    echo "$DEFAULT_REPO"
}

# ─── Stack/message extraction ───
# Use jq when available so multi-line strings and JSON escapes round-trip
# correctly. Truncate by lines, not bytes — byte truncation routinely lands
# inside an escape sequence and produces unreadable issue bodies.
extract_field() {
    local line="$1" field="$2" max_lines="${3:-10}"
    if [ "$HAS_JQ" -eq 1 ]; then
        echo "$line" | jq -r ".error.${field} // .${field} // empty" 2>/dev/null | head -n "$max_lines"
    else
        echo "$line" | grep -oP "\"${field}\":\"[^\"]*\"" | sed "s/\"${field}\":\"//;s/\\\\n/\n/g;s/\"\$//" | head -n "$max_lines"
    fi
}

# ─── Error pattern matching ───
ERROR_PATTERN='"level":"error"|ERROR|\[ERROR\]|FATAL|PANIC|Unhandled|uncaughtException|unhandledRejection'
EXCLUDE_PATTERN='pg_isready|redis-cli|redo done|checkpoint starting|checkpoint complete|PermissionError|ECONNREFUSED.*healthcheck'

# ─── Counters for heartbeat ───
total_containers=0
total_errors=0
total_skipped_no_repo=0
total_deduped=0
issues_created=0
comments_added=0

# ─── Main loop ───
CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null)
if [ -z "$CONTAINERS" ]; then
    echo "[$(ts)] No running containers found" >&2
    exit 0
fi

for container in $CONTAINERS; do
    total_containers=$((total_containers + 1))
    REPO=$(get_repo "$container")
    if [ -z "$REPO" ]; then
        total_skipped_no_repo=$((total_skipped_no_repo + 1))
        echo "[$(ts)] WARN: no repo mapping for container '$container' — add to ${WATCHER_CONFIG:-$HOME/.docker-watcher/repos.conf}" >&2
        continue
    fi

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        total_errors=$((total_errors + 1))

        [ "$issues_created" -ge "$MAX_ISSUES_PER_RUN" ] && break

        error_msg=$(extract_field "$line" "message" 1)
        if [ -z "$error_msg" ]; then
            error_msg=$(echo "$line" | sed 's/^.*\[ERROR\] //' | head -c 200)
        fi
        [ -z "$error_msg" ] && continue

        # Per-line trimming for the title (single line, ≤120 chars)
        error_msg_short=$(echo "$error_msg" | head -1 | head -c 200)

        route=$(echo "$line" | grep -oP '"route":"[^"]*"' | sed 's/"route":"//;s/"$//')

        # Dedup hash now includes route so distinct endpoints with the same
        # generic message ("Unhandled API error") get tracked separately.
        error_hash=$(echo "$container:$route:$error_msg_short" | md5sum | cut -d' ' -f1)
        state_file="$STATE_DIR/$error_hash"

        if [ -f "$state_file" ]; then
            last_report=$(cat "$state_file")
            now=$(date +%s)
            elapsed=$((now - last_report))
            if [ "$elapsed" -lt "$COOLDOWN" ]; then
                total_deduped=$((total_deduped + 1))
                continue
            fi
        fi

        stack=$(extract_field "$line" "stack" 15)

        # Title now includes route when available so distinct failure modes
        # don't collapse to a single bucket via the dedup search below.
        if [ -n "$route" ]; then
            title="[auto] ${container} ${route}: ${error_msg_short}"
        else
            title="[auto] ${container}: ${error_msg_short}"
        fi
        title=$(echo "$title" | head -c 120)

        # Check if similar issue already exists. We search by container+route
        # so two distinct routes with the same generic message don't merge.
        search_scope="[auto] ${container}"
        [ -n "$route" ] && search_scope="${search_scope} ${route}"

        existing=$(gh issue list --repo "$REPO" --state open \
            --search "in:title $search_scope" \
            --limit 5 --json number,title \
            --jq ".[] | select(.title | startswith(\"$search_scope\")) | .number" \
            2>/dev/null | head -1)

        if [ -n "$existing" ] && [ "$existing" != "null" ]; then
            if gh issue comment "$existing" --repo "$REPO" --body "$(cat <<COMMENT
Recurrence detected: $(ts)

\`\`\`
$error_msg_short
\`\`\`

🤖 docker-error-watcher
COMMENT
)" >/dev/null 2>&1; then
                date +%s > "$state_file"
                comments_added=$((comments_added + 1))
                echo "[$(ts)] Comment added to $REPO#$existing for $container ${route:-} ${error_msg_short}" >&2
            else
                echo "[$(ts)] WARN: failed to comment on $REPO#$existing" >&2
            fi
            continue
        fi

        if gh issue create --repo "$REPO" \
            --title "$title" \
            --label "bug,auto-reported" \
            --body "$(cat <<BODY
## Error detected automatically

| Field | Value |
|-------|-------|
| **Container** | \`$container\` |
| **Host** | \`$(hostname)\` |
| **Detected at** | $(ts) |
| **Route** | \`${route:-N/A}\` |

## Error message

\`\`\`
$error_msg_short
\`\`\`

## Stack trace

\`\`\`
$stack
\`\`\`

## Full log line

\`\`\`
$(echo "$line" | head -c 2000)
\`\`\`

---
🤖 Reported by [docker-error-watcher](https://github.com/bot202102/docker-error-watcher)
BODY
)" >/dev/null 2>&1; then
            date +%s > "$state_file"
            issues_created=$((issues_created + 1))
            echo "[$(ts)] Issue created in $REPO for $container ${route:-} ${error_msg_short}" >&2
        else
            echo "[$(ts)] WARN: gh issue create failed for $REPO ($container)" >&2
        fi
    done < <(docker logs --since "$LOG_WINDOW" "$container" 2>&1 \
        | grep -iE "$ERROR_PATTERN" \
        | grep -viE "$EXCLUDE_PATTERN")
done

# Heartbeat: always log a summary so operators can confirm the watcher is
# running even when there's nothing to report. Previously the log file
# stayed at 0 bytes indefinitely which masked misconfiguration for weeks.
echo "[$(ts)] Scanned $total_containers containers, found $total_errors error lines, created $issues_created issues, added $comments_added comments, $total_deduped deduped, $total_skipped_no_repo containers without repo mapping"

# Clean up old state files (>7 days)
find "$STATE_DIR" -maxdepth 1 -type f ! -name 'repos.conf' ! -name 'watcher.log' -mtime +7 -delete 2>/dev/null
