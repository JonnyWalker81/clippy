#!/usr/bin/env bash
# Native clipboard sync for NixOS/Linux (HTTP Client Mode)
# Bidirectional clipboard sync using xclip/xsel/wl-clipboard and HTTP API

set -euo pipefail

# Configuration
SERVER_URL="${CLIPBOARD_SERVER_URL:-http://10.211.55.2:8080}"
POLL_INTERVAL="${CLIPBOARD_POLL_INTERVAL:-0.2}"  # 200ms
VERBOSE="${CLIPBOARD_VERBOSE:-1}"
LOG_FILE="${CLIPBOARD_LOG:-/tmp/native-sync-nixos.log}"

# State file to track last clipboard
STATE_DIR="/tmp/native-sync-nixos"
mkdir -p "$STATE_DIR"
LAST_SENT_HASH_FILE="$STATE_DIR/last_sent_hash"
LAST_RECEIVED_ID_FILE="$STATE_DIR/last_received_id"
CLIPBOARD_CACHE="$STATE_DIR/clipboard_cache"

# Clipboard tool selection
CLIPBOARD_TOOL=""
CLIPBOARD_READ_CMD=""
CLIPBOARD_WRITE_CMD=""

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

# Detect available clipboard tool
detect_clipboard_tool() {
    if [ -n "$WAYLAND_DISPLAY" ]; then
        if command -v wl-paste &> /dev/null && command -v wl-copy &> /dev/null; then
            CLIPBOARD_TOOL="wayland"
            CLIPBOARD_READ_CMD="wl-paste -n"
            CLIPBOARD_WRITE_CMD="wl-copy"
            log "✓ Using Wayland clipboard (wl-clipboard)"
            return 0
        fi
    fi

    if [ -n "${DISPLAY:-}" ]; then
        if command -v xclip &> /dev/null; then
            CLIPBOARD_TOOL="xclip"
            CLIPBOARD_READ_CMD="xclip -o -selection clipboard"
            CLIPBOARD_WRITE_CMD="xclip -selection clipboard"
            log "✓ Using X11 clipboard (xclip)"
            return 0
        elif command -v xsel &> /dev/null; then
            CLIPBOARD_TOOL="xsel"
            CLIPBOARD_READ_CMD="xsel --clipboard --output"
            CLIPBOARD_WRITE_CMD="xsel --clipboard --input"
            log "✓ Using X11 clipboard (xsel)"
            return 0
        fi
    fi

    log "❌ Error: No clipboard tool found!"
    log "   Install: xclip (X11) or wl-clipboard (Wayland)"
    return 1
}

# Get clipboard content
get_clipboard() {
    if [ -z "$CLIPBOARD_READ_CMD" ]; then
        return 1
    fi

    # Try multiple targets for xclip (handle compatibility issues)
    if [ "$CLIPBOARD_TOOL" = "xclip" ]; then
        local content=""
        # Try UTF8_STRING first (most reliable for modern terminals like Ghostty)
        for target in UTF8_STRING STRING TEXT text/plain; do
            content=$(xclip -o -selection clipboard -t "$target" 2>/dev/null || echo "")

            # Validate content: reject suspicious single-character results
            # These are often error indicators or partial reads
            if [ -n "$content" ] && [ ${#content} -gt 1 ]; then
                echo "$content"
                return 0
            elif [ -n "$content" ] && [ ${#content} -eq 1 ]; then
                # Single character - only accept if it's alphanumeric
                if [[ "$content" =~ ^[a-zA-Z0-9]$ ]]; then
                    echo "$content"
                    return 0
                fi
                # Otherwise, try next target
            fi
        done
        return 1
    else
        $CLIPBOARD_READ_CMD 2>/dev/null || echo ""
    fi
}

# Set clipboard content
set_clipboard() {
    local content="$1"
    if [ -n "$content" ] && [ -n "$CLIPBOARD_WRITE_CMD" ]; then
        echo -n "$content" | $CLIPBOARD_WRITE_CMD 2>/dev/null
        return $?
    fi
    return 1
}

# Calculate hash of clipboard
get_clipboard_hash() {
    local content="$1"
    echo -n "$content" | md5sum | cut -d' ' -f1
}

# Parse JSON value (simple extraction without jq dependency)
json_value() {
    local key="$1"
    local json="$2"
    # More robust: match the value between quotes or as a number
    # Handles: "key":"value" or "key":123
    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*:[[:space:]]*"//' | sed 's/"$//' || \
    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" | sed 's/.*:[[:space:]]*//'
}

# Send clipboard to server
send_to_server() {
    local content="$1"
    local encoded=$(echo -n "$content" | base64 -w 0)

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

            # Remove potential quotes and newlines from content
            encoded_content=$(echo "$encoded_content" | tr -d '"\n')

            if [ -n "$id" ] && [ "$id" -gt "$last_received_id" ]; then
                # Read last sent hash to prevent echo
                local last_sent_hash=""
                if [ -f "$LAST_SENT_HASH_FILE" ]; then
                    last_sent_hash=$(cat "$LAST_SENT_HASH_FILE")
                fi

                # Decode content first to compute proper hash
                local content=$(echo "$encoded_content" | base64 -d 2>/dev/null || echo "")

                if [ -n "$content" ]; then
                    # Compute hash of decoded content (not server's base64 hash)
                    local content_hash=$(get_clipboard_hash "$content")

                    # Only apply if different from what we sent
                    if [ "$content_hash" != "$last_sent_hash" ]; then
                        local preview="${content:0:50}"
                        [ ${#content} -gt 50 ] && preview="${preview}..."
                        log "📥 Received from server: id=$id, '$preview' (${#content} bytes, hash: ${content_hash:0:8})"

                        if set_clipboard "$content"; then
                            echo "$content" > "$CLIPBOARD_CACHE"
                            echo "$id" > "$LAST_RECEIVED_ID_FILE"
                            echo "$content_hash" > "$LAST_SENT_HASH_FILE"  # Store hash of decoded content
                            last_received_id=$id
                            last_sent_hash="$content_hash"
                            log "✅ Applied to local clipboard"
                        else
                            log "❌ Failed to apply to clipboard"
                        fi
                    fi
                    # Silently skip if hash matches (no log spam)
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

    # Detect clipboard tool
    if ! detect_clipboard_tool; then
        exit 1
    fi

    # Check for curl
    if ! command -v curl &> /dev/null; then
        log "❌ Error: curl not found"
        log "   Install with: nix-shell -p curl"
        exit 1
    fi

    # Test server connectivity
    log "🔗 Testing server connectivity..."
    if ! curl -s -f "$SERVER_URL/health" > /dev/null 2>&1; then
        log "⚠️  Warning: Cannot reach server at $SERVER_URL"
        log "   Make sure clipboard_server is running on the host"
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
    echo "=== Native Sync Health Check (NixOS HTTP Client) ==="
    echo

    # Check if process is running
    if pgrep -f "native-sync-nixos.sh" > /dev/null; then
        echo "✓ Native sync is running (PID: $(pgrep -f 'native-sync-nixos.sh' | head -1))"
    else
        echo "✗ Native sync is not running"
    fi

    # Check clipboard tools
    detect_clipboard_tool &> /dev/null
    if [ -n "$CLIPBOARD_TOOL" ]; then
        echo "✓ Clipboard tool available: $CLIPBOARD_TOOL"
        local content=$(get_clipboard 2>/dev/null || echo "")
        if [ -n "$content" ]; then
            echo "  Current clipboard: ${content:0:50}"
        else
            echo "  Current clipboard: (empty)"
        fi
    else
        echo "✗ No clipboard tool available"
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

    # Environment info
    echo
    echo "Environment:"
    echo "  DISPLAY: ${DISPLAY:-<not set>}"
    echo "  WAYLAND_DISPLAY: ${WAYLAND_DISPLAY:-<not set>}"
    echo "  XDG_SESSION_TYPE: ${XDG_SESSION_TYPE:-<not set>}"
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
        pkill -f "native-sync-nixos.sh" || echo "No process found"
        ;;
    *)
        echo "Usage: $0 {start|stop|check|health|status}"
        echo
        echo "Environment variables:"
        echo "  CLIPBOARD_SERVER_URL    - Server URL (default: http://10.211.55.2:8080)"
        echo "  CLIPBOARD_POLL_INTERVAL - Poll interval in seconds (default: 0.2)"
        echo "  CLIPBOARD_VERBOSE       - Enable verbose output (default: 1)"
        echo "  CLIPBOARD_LOG           - Log file path (default: /tmp/native-sync-nixos.log)"
        exit 1
        ;;
esac
