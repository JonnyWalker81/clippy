#!/usr/bin/env bash
# Native clipboard sync for macOS (Server Mode)
# Bidirectional clipboard sync using pbcopy/pbpaste and TCP sockets

set -euo pipefail

# Configuration
PORT="${NATIVE_SYNC_PORT:-9877}"
POLL_INTERVAL="${NATIVE_SYNC_INTERVAL:-0.2}"  # 200ms
VERBOSE="${NATIVE_SYNC_VERBOSE:-1}"
LOG_FILE="${NATIVE_SYNC_LOG:-/tmp/native-sync-macos.log}"

# State file to track last clipboard
STATE_DIR="/tmp/native-sync-$$"
mkdir -p "$STATE_DIR"
LAST_HASH_FILE="$STATE_DIR/last_hash"
CLIPBOARD_CACHE="$STATE_DIR/clipboard_cache"
CLIENT_PIPE="$STATE_DIR/client_pipe"

# Cleanup on exit
cleanup() {
    log "🛑 Shutting down native sync..."
    rm -rf "$STATE_DIR"
    pkill -P $$ || true
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

# Send clipboard to clients
send_to_clients() {
    local content="$1"
    local encoded=$(echo -n "$content" | base64)
    local hash=$(get_clipboard_hash "$content")
    local preview="${content:0:50}"
    [ ${#content} -gt 50 ] && preview="${preview}..."

    log "📤 Sending to clients: '$preview' (${#content} bytes, hash: ${hash:0:8})"
    echo "CLIP:$encoded" >> "$CLIENT_PIPE"
}

# Monitor local clipboard changes
monitor_clipboard() {
    log "👀 Starting clipboard monitor (polling every ${POLL_INTERVAL}s)"
    local last_hash=""

    while true; do
        local content=$(get_clipboard)

        if [ -n "$content" ]; then
            local current_hash=$(get_clipboard_hash "$content")

            if [ "$current_hash" != "$last_hash" ]; then
                local preview="${content:0:50}"
                [ ${#content} -gt 50 ] && preview="${preview}..."
                log "🔍 Local clipboard changed: '$preview' (${#content} bytes, hash: ${current_hash:0:8})"

                # Update state
                echo "$current_hash" > "$LAST_HASH_FILE"
                echo "$content" > "$CLIPBOARD_CACHE"
                last_hash="$current_hash"

                # Send to clients if pipe exists
                if [ -p "$CLIENT_PIPE" ]; then
                    send_to_clients "$content"
                fi
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

# Handle client connection
handle_client() {
    local client_id="$1"
    log "🔗 Client $client_id connected"

    # Send current clipboard immediately
    if [ -f "$CLIPBOARD_CACHE" ]; then
        local content=$(cat "$CLIPBOARD_CACHE")
        if [ -n "$content" ]; then
            local encoded=$(echo -n "$content" | base64)
            echo "CLIP:$encoded"
            log "📤 Sent initial clipboard to client $client_id"
        fi
    fi

    # Handle incoming messages
    while IFS= read -r line; do
        if [[ "$line" =~ ^CLIP:(.+)$ ]]; then
            local encoded="${BASH_REMATCH[1]}"
            local content=$(echo "$encoded" | base64 -D 2>/dev/null || echo "")

            if [ -n "$content" ]; then
                local hash=$(get_clipboard_hash "$content")
                local preview="${content:0:50}"
                [ ${#content} -gt 50 ] && preview="${preview}..."

                log "📥 Received from client $client_id: '$preview' (${#content} bytes, hash: ${hash:0:8})"

                # Apply to local clipboard
                if set_clipboard "$content"; then
                    echo "$hash" > "$LAST_HASH_FILE"
                    echo "$content" > "$CLIPBOARD_CACHE"
                    log "✅ Applied to local clipboard"
                    echo "ACK:$hash"
                else
                    log "❌ Failed to apply to clipboard"
                    echo "NAK"
                fi
            fi
        elif [[ "$line" == "PING" ]]; then
            echo "PONG"
        fi
    done

    log "👋 Client $client_id disconnected"
}

# Main server loop
start_server() {
    log "🚀 Starting native clipboard sync server on port $PORT"
    log "📍 Log file: $LOG_FILE"
    log "📂 State directory: $STATE_DIR"

    # Check for required tools
    if ! command -v pbcopy &> /dev/null || ! command -v pbpaste &> /dev/null; then
        log "❌ Error: pbcopy/pbpaste not found (are you on macOS?)"
        exit 1
    fi

    if ! command -v socat &> /dev/null; then
        log "⚠️  Warning: socat not found, trying nc fallback..."
        log "   Install socat for better performance: brew install socat"
    fi

    # Create named pipe for broadcasting to clients
    mkfifo "$CLIENT_PIPE" 2>/dev/null || true

    # Start clipboard monitor in background
    monitor_clipboard &
    local monitor_pid=$!

    # Start server
    if command -v socat &> /dev/null; then
        log "✓ Using socat for TCP server"
        # Use socat for bidirectional communication
        local client_counter=0
        while true; do
            client_counter=$((client_counter + 1))
            socat TCP-LISTEN:$PORT,reuseaddr,fork SYSTEM:"$(declare -f handle_client); handle_client $client_counter" &
            wait $!
        done
    else
        log "✓ Using nc for TCP server (fallback)"
        # Fallback to nc (less reliable)
        while true; do
            nc -l "$PORT" | handle_client "nc-client"
        done
    fi
}

# Health check mode
health_check() {
    echo "=== Native Sync Health Check (macOS) ==="
    echo

    # Check if process is running
    if pgrep -f "native-sync-macos.sh" > /dev/null; then
        echo "✓ Native sync is running (PID: $(pgrep -f 'native-sync-macos.sh'))"
    else
        echo "✗ Native sync is not running"
    fi

    # Check if port is listening
    if lsof -i ":$PORT" -sTCP:LISTEN &> /dev/null; then
        echo "✓ Server listening on port $PORT"
    else
        echo "✗ Server not listening on port $PORT"
    fi

    # Check clipboard tools
    if command -v pbcopy &> /dev/null && command -v pbpaste &> /dev/null; then
        echo "✓ Clipboard tools available (pbcopy/pbpaste)"
        echo "  Current clipboard: $(pbpaste 2>/dev/null | head -c 50)"
    else
        echo "✗ Clipboard tools not available"
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
        start_server
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
        echo "  NATIVE_SYNC_PORT       - TCP port (default: 9877)"
        echo "  NATIVE_SYNC_INTERVAL   - Poll interval in seconds (default: 0.2)"
        echo "  NATIVE_SYNC_VERBOSE    - Enable verbose output (default: 1)"
        echo "  NATIVE_SYNC_LOG        - Log file path (default: /tmp/native-sync-macos.log)"
        exit 1
        ;;
esac
