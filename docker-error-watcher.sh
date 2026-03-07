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

mkdir -p "$STATE_DIR"

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

# False positives to exclude (pipe-separated, case-insensitive)
EXCLUDE_PATTERN='pg_isready|redis-cli|redo done|checkpoint starting|checkpoint complete|PermissionError|ECONNREFUSED.*healthcheck'

# ─── Main loop ───
CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null)
if [ -z "$CONTAINERS" ]; then
    exit 0
fi

issues_created=0

for container in $CONTAINERS; do
    REPO=$(get_repo "$container")
    [ -z "$REPO" ] && continue

    docker logs --since "$LOG_WINDOW" "$container" 2>&1 \
        | grep -iE "$ERROR_PATTERN" \
        | grep -viE "$EXCLUDE_PATTERN" \
        | while IFS= read -r line; do

        [ "$issues_created" -ge "$MAX_ISSUES_PER_RUN" ] && break

        # Extract error message (JSON structured logs or plain text)
        error_msg=$(echo "$line" | grep -oP '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
        if [ -z "$error_msg" ]; then
            error_msg=$(echo "$line" | sed 's/^.*\[ERROR\] //' | head -c 200)
        fi
        [ -z "$error_msg" ] && continue

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

        # Extract additional context from JSON logs
        route=$(echo "$line" | grep -oP '"route":"[^"]*"' | sed 's/"route":"//;s/"$//')
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
done

# Clean up old state files (>7 days)
find "$STATE_DIR" -type f -mtime +7 -delete 2>/dev/null
