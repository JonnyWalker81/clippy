#!/usr/bin/env bash
# Native clipboard sync for macOS (HTTP Client Mode)
# Bidirectional clipboard sync using pbcopy/pbpaste and HTTP API

set -euo pipefail

# Configuration
SERVER_URL="${CLIPBOARD_SERVER_URL:-http://localhost:8080}"
POLL_INTERVAL="${CLIPBOARD_POLL_INTERVAL:-0.2}"  # 200ms
VERBOSE="${CLIPBOARD_VERBOSE:-1}"
LOG_FILE="${CLIPBOARD_LOG:-/tmp/native-sync-macos.log}"

# State file to track last clipboard
STATE_DIR="/tmp/native-sync-macos"
mkdir -p "$STATE_DIR"
LAST_SENT_HASH_FILE="$STATE_DIR/last_sent_hash"
LAST_RECEIVED_ID_FILE="$STATE_DIR/last_received_id"
CLIPBOARD_CACHE="$STATE_DIR/clipboard_cache"

# Cleanup on exit
cleanup() {
    log "🛑 Shutting down native sync..."
    pkill -P $$ || true
    rm -rf "$STATE_DIR"
    exit 0
}
trap cleanup EXIT INT TERM

# Logging function
log() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    if [ "$VERBOSE" = "1" ]; then
        echo "[$timestamp] $msg" | tee -a "$LOG_FILE"
    else
        echo "[$timestamp] $msg" >> "$LOG_FILE"
    fi
}

# Get clipboard content
get_clipboard() {
    pbpaste 2>/dev/null || echo ""
}

# Set clipboard content
set_clipboard() {
    local content="$1"
    if [ -n "$content" ]; then
        echo -n "$content" | pbcopy 2>/dev/null
        return $?
    fi
    return 1
}

# Calculate hash of clipboard
get_clipboard_hash() {
    local content="$1"
    echo -n "$content" | md5 -q
}

# Parse JSON value (simple extraction without jq dependency)
json_value() {
    local key="$1"
    local json="$2"
    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[^,}]*" | sed 's/.*:[[:space:]]*//' | tr -d '"'
}

# Send clipboard to server
send_to_server() {
    local content="$1"
    local encoded=$(echo -n "$content" | base64)

    local response=$(curl -s -X POST "$SERVER_URL/api/clipboard" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"$encoded\"}" 2>/dev/null)

    if [ $? -eq 0 ]; then
        local id=$(json_value "id" "$response")
        local hash=$(json_value "hash" "$response")
        log "📤 Sent to server: id=$id, hash=${hash:0:8}"
        return 0
    else
        log "❌ Failed to send to server"
        return 1
    fi
}

# Get latest clipboard from server
get_from_server() {
    local response=$(curl -s "$SERVER_URL/api/clipboard/latest" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$response" ]; then
        echo "$response"
        return 0
    else
        return 1
    fi
}

# Monitor local clipboard and send changes to server
monitor_local_clipboard() {
    log "🔍 Starting local clipboard monitor"

    # Initialize last sent hash
    local last_sent_hash=""
    if [ -f "$LAST_SENT_HASH_FILE" ]; then
        last_sent_hash=$(cat "$LAST_SENT_HASH_FILE")
    fi

    while true; do
        local content=$(get_clipboard)

        if [ -n "$content" ]; then
            local current_hash=$(get_clipboard_hash "$content")

            if [ "$current_hash" != "$last_sent_hash" ]; then
                local preview="${content:0:50}"
                [ ${#content} -gt 50 ] && preview="${preview}..."
                log "🔍 Local clipboard changed: '$preview' (${#content} bytes, hash: ${current_hash:0:8})"

                if send_to_server "$content"; then
                    echo "$current_hash" > "$LAST_SENT_HASH_FILE"
                    last_sent_hash="$current_hash"
                fi
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

# Poll server for clipboard changes
poll_server() {
    log "📥 Starting server poll loop"

    # Initialize last received ID
    local last_received_id=0
    if [ -f "$LAST_RECEIVED_ID_FILE" ]; then
        last_received_id=$(cat "$LAST_RECEIVED_ID_FILE")
    fi

    while true; do
        local response=$(get_from_server)

        if [ $? -eq 0 ] && [ -n "$response" ]; then
            local id=$(json_value "id" "$response")
            local hash=$(json_value "hash" "$response")
            local encoded_content=$(json_value "content" "$response")

            # Remove potential quotes from content
            encoded_content=$(echo "$encoded_content" | tr -d '"')

            if [ -n "$id" ] && [ "$id" -gt "$last_received_id" ]; then
                # Read last sent hash to prevent echo
                local last_sent_hash=""
                if [ -f "$LAST_SENT_HASH_FILE" ]; then
                    last_sent_hash=$(cat "$LAST_SENT_HASH_FILE")
                fi

                # Only apply if different from what we sent
                if [ "$hash" != "$last_sent_hash" ]; then
                    local content=$(echo "$encoded_content" | base64 -D 2>/dev/null || echo "")

                    if [ -n "$content" ]; then
                        local preview="${content:0:50}"
                        [ ${#content} -gt 50 ] && preview="${preview}..."
                        log "📥 Received from server: id=$id, '$preview' (${#content} bytes, hash: ${hash:0:8})"

                        if set_clipboard "$content"; then
                            echo "$content" > "$CLIPBOARD_CACHE"
                            echo "$id" > "$LAST_RECEIVED_ID_FILE"
                            echo "$hash" > "$LAST_SENT_HASH_FILE"  # Update sent hash to prevent echo
                            last_received_id=$id
                            last_sent_hash="$hash"
                            log "✅ Applied to local clipboard"
                        else
                            log "❌ Failed to apply to clipboard"
                        fi
                    fi
                else
                    log "⏭️  Skipping (hash matches what we sent: ${hash:0:8})"
                fi
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

# Start sync service
start_sync() {
    log "🚀 Starting native clipboard sync (HTTP client)"
    log "📍 Server URL: $SERVER_URL"
    log "📂 State directory: $STATE_DIR"
    log "📄 Log file: $LOG_FILE"

    # Check for required tools
    if ! command -v pbcopy &> /dev/null || ! command -v pbpaste &> /dev/null; then
        log "❌ Error: pbcopy/pbpaste not found (are you on macOS?)"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        log "❌ Error: curl not found"
        exit 1
    fi

    # Test server connectivity
    log "🔗 Testing server connectivity..."
    if ! curl -s -f "$SERVER_URL/health" > /dev/null 2>&1; then
        log "⚠️  Warning: Cannot reach server at $SERVER_URL"
        log "   Make sure clipboard_server is running"
    else
        log "✅ Server is reachable"
    fi

    # Initialize clipboard cache
    local current_clip=$(get_clipboard)
    if [ -n "$current_clip" ]; then
        echo "$current_clip" > "$CLIPBOARD_CACHE"
        get_clipboard_hash "$current_clip" > "$LAST_SENT_HASH_FILE"
    fi

    # Start background processes
    monitor_local_clipboard &
    local monitor_pid=$!

    poll_server &
    local poll_pid=$!

    log "✓ Background processes started (monitor: $monitor_pid, poll: $poll_pid)"

    # Wait for both processes
    wait
}

# Health check mode
health_check() {
    echo "=== Native Sync Health Check (macOS HTTP Client) ==="
    echo

    # Check if process is running
    if pgrep -f "native-sync-macos.sh" > /dev/null; then
        echo "✓ Native sync is running (PID: $(pgrep -f 'native-sync-macos.sh' | head -1))"
    else
        echo "✗ Native sync is not running"
    fi

    # Check clipboard tools
    if command -v pbcopy &> /dev/null && command -v pbpaste &> /dev/null; then
        echo "✓ Clipboard tools available (pbcopy/pbpaste)"
        local content=$(pbpaste 2>/dev/null || echo "")
        if [ -n "$content" ]; then
            echo "  Current clipboard: ${content:0:50}"
        else
            echo "  Current clipboard: (empty)"
        fi
    else
        echo "✗ Clipboard tools not available"
    fi

    # Check server connectivity
    if command -v curl &> /dev/null; then
        echo "✓ curl available"

        if curl -s -f "$SERVER_URL/health" > /dev/null 2>&1; then
            echo "✓ Server reachable at $SERVER_URL"

            # Get server health info
            local health=$(curl -s "$SERVER_URL/health" 2>/dev/null)
            if [ -n "$health" ]; then
                local items=$(json_value "items_count" "$health")
                local uptime=$(json_value "uptime_seconds" "$health")
                echo "  Server items: $items"
                echo "  Server uptime: ${uptime}s"
            fi
        else
            echo "✗ Cannot reach server at $SERVER_URL"
        fi
    else
        echo "✗ curl not available"
    fi

    # Check log file
    if [ -f "$LOG_FILE" ]; then
        echo "✓ Log file exists: $LOG_FILE"
        echo "  Last 3 lines:"
        tail -3 "$LOG_FILE" | sed 's/^/    /'
    else
        echo "✗ No log file found"
    fi
}

# Parse arguments
case "${1:-start}" in
    start)
        start_sync
        ;;
    check|status|health)
        health_check
        ;;
    stop)
        log "🛑 Stopping native sync..."
        pkill -f "native-sync-macos.sh" || echo "No process found"
        ;;
    *)
        echo "Usage: $0 {start|stop|check|health|status}"
        echo
        echo "Environment variables:"
        echo "  CLIPBOARD_SERVER_URL   - Server URL (default: http://localhost:8080)"
        echo "  CLIPBOARD_POLL_INTERVAL - Poll interval in seconds (default: 0.2)"
        echo "  CLIPBOARD_VERBOSE      - Enable verbose output (default: 1)"
        echo "  CLIPBOARD_LOG          - Log file path (default: /tmp/native-sync-macos.log)"
        exit 1
        ;;
esac
