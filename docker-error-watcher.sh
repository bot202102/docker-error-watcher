#!/bin/bash
# ─── Docker Error Watcher → GitHub Issues ───
# Monitors ALL running Docker containers for errors in logs,
# deduplicates them, and auto-creates GitHub Issues.
#
# Features:
#   - Auto-discovers all running containers
#   - Maps containers to GitHub repos by name prefix
#   - Deduplicates errors by content hash
#   - Cooldown per error (default 1 hour)
#   - Flood protection (max issues per run)
#   - Adds comments to existing open issues instead of creating duplicates
#   - Filters out common false positives (healthchecks, WAL recovery, etc.)
#   - Cleans up old state files automatically
#
# Requirements: docker, gh (GitHub CLI, authenticated)
# Usage: Run via cron every 5 minutes
#   */5 * * * * /path/to/docker-error-watcher.sh >> /path/to/watcher.log 2>&1

# ─── Configuration ───
STATE_DIR="${WATCHER_STATE_DIR:-$HOME/.docker-watcher}"
COOLDOWN="${WATCHER_COOLDOWN:-3600}"          # Seconds between reports of same error
MAX_ISSUES_PER_RUN="${WATCHER_MAX_ISSUES:-5}" # Anti-flood: max issues per execution
LOG_WINDOW="${WATCHER_LOG_WINDOW:-5m}"        # How far back to check logs
DEFAULT_REPO="${WATCHER_DEFAULT_REPO:-}"      # Fallback repo (leave empty to skip unknown containers)

# Metrics + alerting (additive, all optional):
METRICS_FILE="${WATCHER_METRICS_FILE:-$STATE_DIR/metrics.jsonl}"  # JSONL per-run rollups
METRICS_RETENTION_DAYS="${WATCHER_METRICS_RETENTION_DAYS:-30}"    # Rotate after N days
RATE_THRESHOLD="${WATCHER_RATE_THRESHOLD:-0}"  # If >0, create "rate spike" issue when a single (container, route) exceeds N errors in LOG_WINDOW. Default off.
WEBHOOK_URL="${WATCHER_WEBHOOK_URL:-}"          # If set, POST summary JSON to this URL per-run
HOSTNAME_OVERRIDE="${WATCHER_HOSTNAME:-$(hostname)}"

mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$METRICS_FILE")"

# ─── Container → Repo mapping ───
# Customize this function for your setup.
# Maps container name prefixes to GitHub repos.
# Example: container "myapp-web" matches "myapp-*" → "myorg/myapp"
get_repo() {
    local container="$1"

    # Read mappings from config file if it exists
    local config_file="${WATCHER_CONFIG:-$HOME/.docker-watcher/repos.conf}"
    if [ -f "$config_file" ]; then
        while IFS='=' read -r pattern repo; do
            # Skip comments and empty lines
            [[ "$pattern" =~ ^#.*$ ]] && continue
            [ -z "$pattern" ] && continue
            # Match container name against pattern
            if [[ "$container" == $pattern ]]; then
                echo "$repo"
                return
            fi
        done < "$config_file"
    fi

    echo "$DEFAULT_REPO"
}

# ─── Error pattern matching ───
ERROR_PATTERN='"level":"error"|ERROR|\[ERROR\]|FATAL|PANIC|Unhandled|uncaughtException|unhandledRejection'

# False positives to exclude (pipe-separated, case-insensitive).
# WATCHER_EXTRA_EXCLUDE_PATTERN lets operators suppress newly classified
# benign noise without editing the script.
BASE_EXCLUDE_PATTERN='pg_isready|redis-cli|redo done|checkpoint starting|checkpoint complete|PermissionError|ECONNREFUSED.*healthcheck|^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}([,.][0-9]+)?[[:space:]]+INFO[[:space:]]|(^|[,{][[:space:]]*)"level"[[:space:]]*:[[:space:]]*"info"|Redis broker listen interrupted; retrying|Qdrant .*indexes ensured:.*errors=\[\]'
if [ -n "${WATCHER_EXTRA_EXCLUDE_PATTERN:-}" ]; then
    EXCLUDE_PATTERN="${BASE_EXCLUDE_PATTERN}|${WATCHER_EXTRA_EXCLUDE_PATTERN}"
else
    EXCLUDE_PATTERN="$BASE_EXCLUDE_PATTERN"
fi

# Test hook: load configuration/patterns without scanning Docker logs.
if [ "${WATCHER_TEST_LOAD_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# ─── Main loop ───
CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null)
if [ -z "$CONTAINERS" ]; then
    exit 0
fi

issues_created=0
run_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
run_epoch=$(date +%s)

# Per-run tally: counts keyed by "container|route". Populated while scanning
# logs; emitted to metrics file and optional webhook at end of run.
declare -A RATE_TALLY
declare -A RATE_SAMPLE_MSG   # first error message per key, for context

for container in $CONTAINERS; do
    REPO=$(get_repo "$container")
    [ -z "$REPO" ] && continue

    # NOTE: the while-loop reads logs via a pipeline → runs in a subshell.
    # Tally maps cannot escape a subshell, so we fan out counts via a
    # temp file and read them back in the main shell at the end of the
    # container loop (see below).
    tally_tmp=$(mktemp)
    docker logs --since "$LOG_WINDOW" "$container" 2>&1 \
        | grep -iE "$ERROR_PATTERN" \
        | grep -viE "$EXCLUDE_PATTERN" \
        | while IFS= read -r line; do

        # Extract error message (JSON structured logs or plain text)
        error_msg=$(echo "$line" | grep -oP '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
        if [ -z "$error_msg" ]; then
            error_msg=$(echo "$line" | sed 's/^.*\[ERROR\] //' | head -c 200)
        fi
        [ -z "$error_msg" ] && continue

        # Extract route early — needed for rate tally even if we skip issue creation
        route=$(echo "$line" | grep -oP '"route":"[^"]*"' | sed 's/"route":"//;s/"$//')
        route="${route:-N/A}"

        # Tally (written to temp file; aggregated by main shell after loop)
        # Format: container|route|sample_message
        # The sample is only kept for the first occurrence; awk dedupes.
        echo "$container|$route|$error_msg" >> "$tally_tmp"

        [ "$issues_created" -ge "$MAX_ISSUES_PER_RUN" ] && continue

        # Deduplicate by content hash
        error_hash=$(echo "$container:$error_msg" | md5sum | cut -d' ' -f1)
        state_file="$STATE_DIR/$error_hash"

        # Check cooldown
        if [ -f "$state_file" ]; then
            last_report=$(cat "$state_file")
            now=$(date +%s)
            elapsed=$((now - last_report))
            [ "$elapsed" -lt "$COOLDOWN" ] && continue
        fi

        # Stack trace context (route already extracted above for tally)
        stack=$(echo "$line" | grep -oP '"stack":"[^"]*"' | head -c 500 | sed 's/"stack":"//;s/"$//')

        # Build issue title
        title="[auto] ${container}: ${error_msg}"
        title=$(echo "$title" | head -c 120)

        # Check if similar issue already exists
        search_term=$(echo "$error_msg" | head -c 60)
        existing=$(gh issue list --repo "$REPO" --state open \
            --search "in:title [auto] ${container}" \
            --limit 5 --json number,title \
            --jq ".[] | select(.title | contains(\"$search_term\")) | .number" \
            2>/dev/null | head -1)

        if [ -n "$existing" ] && [ "$existing" != "null" ]; then
            gh issue comment "$existing" --repo "$REPO" --body "$(cat <<COMMENT
Recurrence detected: $(date -u '+%Y-%m-%d %H:%M UTC')

\`\`\`
$error_msg
\`\`\`

🤖 docker-error-watcher
COMMENT
)" 2>/dev/null
            date +%s > "$state_file"
            continue
        fi

        # Create new issue
        gh issue create --repo "$REPO" \
            --title "$title" \
            --label "bug,auto-reported" \
            --body "$(cat <<BODY
## Error detected automatically

| Field | Value |
|-------|-------|
| **Container** | \`$container\` |
| **Host** | \`$(hostname)\` |
| **Date** | $(date -u '+%Y-%m-%d %H:%M UTC') |
| **Route** | \`${route:-N/A}\` |

## Error message

\`\`\`
$error_msg
\`\`\`

## Stack trace

\`\`\`
$(echo "$stack" | sed 's/\\n/\n/g' | head -20)
\`\`\`

## Full log line

\`\`\`
$(echo "$line" | head -c 2000)
\`\`\`

---
🤖 Reported by [docker-error-watcher](https://github.com/bot202102/docker-error-watcher)
BODY
)" 2>/dev/null

        if [ $? -eq 0 ]; then
            date +%s > "$state_file"
            issues_created=$((issues_created + 1))
            echo "[$(date)] Issue created in $REPO for $container: $error_msg"
        fi
    done

    # ── Aggregate tally from the subshell's temp file ──
    if [ -s "$tally_tmp" ]; then
        while IFS='|' read -r tc troute tmsg; do
            key="${tc}|${troute}"
            RATE_TALLY[$key]=$(( ${RATE_TALLY[$key]:-0} + 1 ))
            if [ -z "${RATE_SAMPLE_MSG[$key]:-}" ]; then
                RATE_SAMPLE_MSG[$key]="$tmsg"
            fi
        done < "$tally_tmp"
    fi
    rm -f "$tally_tmp"
done

# ─── Emit per-run metrics ───────────────────────────────────────────
# JSONL format: one line per (container, route) key with count + sample.
# Downstream consumers: tail for Prometheus textfile exporter, grep for
# on-call triage, or forward via webhook below.

metrics_lines=""
for key in "${!RATE_TALLY[@]}"; do
    tc="${key%%|*}"
    troute="${key##*|}"
    count="${RATE_TALLY[$key]}"
    sample="${RATE_SAMPLE_MSG[$key]:-}"
    esc_sample=$(echo "$sample" | sed 's/\\/\\\\/g; s/"/\\"/g' | head -c 300)
    line="{\"ts\":\"${run_timestamp}\",\"host\":\"${HOSTNAME_OVERRIDE}\",\"container\":\"${tc}\",\"route\":\"${troute}\",\"count\":${count},\"window\":\"${LOG_WINDOW}\",\"sample\":\"${esc_sample}\"}"
    echo "$line" >> "$METRICS_FILE"
    metrics_lines="${metrics_lines}${line}
"

    # Rate-spike alerting (opt-in via WATCHER_RATE_THRESHOLD>0)
    if [ "$RATE_THRESHOLD" -gt 0 ] && [ "$count" -ge "$RATE_THRESHOLD" ]; then
        REPO=$(get_repo "$tc")
        [ -z "$REPO" ] && continue
        today=$(date -u '+%Y-%m-%d')
        spike_hash=$(echo "rate:${tc}:${troute}:${today}" | md5sum | cut -d' ' -f1)
        spike_state="$STATE_DIR/$spike_hash"
        [ -f "$spike_state" ] && continue
        spike_title="[auto] rate-spike ${tc} ${troute}: ${count} errors in ${LOG_WINDOW}"
        spike_title=$(echo "$spike_title" | head -c 120)
        gh issue create --repo "$REPO" \
            --title "$spike_title" \
            --label "bug,auto-reported,rate-spike" \
            --body "$(cat <<BODY
## Rate spike detected

| Field | Value |
|-------|-------|
| **Container** | \`$tc\` |
| **Route** | \`$troute\` |
| **Host** | \`$HOSTNAME_OVERRIDE\` |
| **Date** | $run_timestamp |
| **Error count** | **$count** in last \`$LOG_WINDOW\` |
| **Threshold** | $RATE_THRESHOLD |

## Sample error

\`\`\`
$sample
\`\`\`

This issue is distinct from the per-error content-dedup issues —
it fires when the RATE of errors on a single (container, route) exceeds
the threshold, regardless of whether each unique error already has an
open issue. Deduped once per day per (container, route).

---
🤖 Reported by [docker-error-watcher](https://github.com/bot202102/docker-error-watcher) · rate-spike alert
BODY
)" 2>/dev/null && {
            date +%s > "$spike_state"
            echo "[$(date)] Rate spike issue created in $REPO: $tc $troute count=$count"
        }
    fi
done

# ─── Optional webhook ───────────────────────────────────────────────
if [ -n "$WEBHOOK_URL" ] && [ -n "$metrics_lines" ]; then
    events_json=$(echo "$metrics_lines" | grep -v '^$' | sed 's/$/,/' | sed '$s/,$//')
    summary_payload="{\"ts\":\"${run_timestamp}\",\"host\":\"${HOSTNAME_OVERRIDE}\",\"window\":\"${LOG_WINDOW}\",\"events\":[${events_json}]}"
    curl -sS -X POST -H 'Content-Type: application/json' \
        --data "$summary_payload" \
        "$WEBHOOK_URL" >/dev/null 2>&1 \
        && echo "[$(date)] Webhook posted: ${#RATE_TALLY[@]} events"
fi

# ─── State file housekeeping ─────────────────────────────────────────
# Clean up old error-dedup state files (>7 days)
find "$STATE_DIR" -type f -mtime +7 -not -name 'metrics.jsonl*' -delete 2>/dev/null

# Rotate the metrics JSONL if it's older than retention window
if [ -f "$METRICS_FILE" ]; then
    if find "$METRICS_FILE" -mtime "+$METRICS_RETENTION_DAYS" 2>/dev/null | grep -q .; then
        mv "$METRICS_FILE" "${METRICS_FILE}.$(date -u '+%Y%m%d')"
        # Compress historical rotations older than 7 days
        find "$(dirname "$METRICS_FILE")" -name "$(basename "$METRICS_FILE").[0-9]*" \
            -mtime +7 -not -name '*.gz' -exec gzip {} \; 2>/dev/null
    fi
fi
