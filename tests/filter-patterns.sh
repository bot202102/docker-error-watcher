#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WATCHER_TEST_LOAD_ONLY=1 source "$REPO_DIR/docker-error-watcher.sh"

assert_filtered() {
    local line="$1"
    if printf '%s\n' "$line" | grep -iE "$ERROR_PATTERN" | grep -viE "$EXCLUDE_PATTERN" >/dev/null; then
        printf 'expected line to be filtered, but it passed: %s\n' "$line" >&2
        exit 1
    fi
}

assert_detected() {
    local line="$1"
    if ! printf '%s\n' "$line" | grep -iE "$ERROR_PATTERN" | grep -viE "$EXCLUDE_PATTERN" >/dev/null; then
        printf 'expected line to be detected, but it was filtered: %s\n' "$line" >&2
        exit 1
    fi
}

assert_filtered '[enhanced_processing.queue.broker][WARNING][worker-1] Redis broker listen interrupted; retrying: TimeoutError: Timeout reading from redis:6379'
assert_filtered '2026-06-27 22:46:41 INFO     enhanced_processing.mcp.asgi: Qdrant pages indexes ensured: created=["idx"] existed=[] errors=[]'
assert_filtered '{"level":"info","message":"Qdrant pages indexes ensured: created=[\"idx\"] existed=[] errors=[]"}'
assert_detected '[app][ERROR] database write failed permanently'
assert_detected '2026-06-27 22:46:41 ERROR    enhanced_processing.mcp.asgi: Qdrant pages indexes ensured: created=[] existed=[] errors=["connection refused"]'
assert_detected '[app][ERROR] failed to fetch INFO record'
assert_detected '{"level":"error","message":"failed to fetch INFO record"}'

(
    WATCHER_EXTRA_EXCLUDE_PATTERN='temporary upstream retry'
    WATCHER_TEST_LOAD_ONLY=1 source "$REPO_DIR/docker-error-watcher.sh"
    assert_filtered '[gateway][ERROR] temporary upstream retry after 503'
)

printf 'filter-patterns: ok\n'
