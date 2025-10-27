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
STATE_DIR="/tmp/native-sync-server"
mkdir -p "$STATE_DIR"
LAST_HASH_FILE="$STATE_DIR/last_hash"
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

# Handle client connection
handle_client() {
    log "🔗 Client connected from $SOCAT_PEERADDR:$SOCAT_PEERPORT"

    # Send current clipboard immediately if available
    if [ -f "$CLIPBOARD_CACHE" ]; then
        local content=$(cat "$CLIPBOARD_CACHE")
        if [ -n "$content" ]; then
            local encoded=$(echo -n "$content" | base64)
            echo "CLIP:$encoded"
            log "📤 Sent initial clipboard to client"
        fi
    fi

    # Handle incoming messages and send periodic clipboard updates
    local last_sent_hash=""
    if [ -f "$LAST_HASH_FILE" ]; then
        last_sent_hash=$(cat "$LAST_HASH_FILE")
    fi

    while true; do
        # Check for incoming data (non-blocking)
        if read -r -t 0.1 line 2>/dev/null; then
            if [[ "$line" =~ ^CLIP:(.+)$ ]]; then
                local encoded="${BASH_REMATCH[1]}"
                local content=$(echo "$encoded" | base64 -D 2>/dev/null || echo "")

                if [ -n "$content" ]; then
                    local hash=$(get_clipboard_hash "$content")
                    local preview="${content:0:50}"
                    [ ${#content} -gt 50 ] && preview="${preview}..."

                    log "📥 Received from client: '$preview' (${#content} bytes, hash: ${hash:0:8})"

                    # Apply to local clipboard
                    if set_clipboard "$content"; then
                        echo "$hash" > "$LAST_HASH_FILE"
                        echo "$content" > "$CLIPBOARD_CACHE"
                        last_sent_hash="$hash"
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
        fi

        # Check if local clipboard changed and send to client
        if [ -f "$CLIPBOARD_CACHE" ]; then
            local content=$(get_clipboard)
            if [ -n "$content" ]; then
                local current_hash=$(get_clipboard_hash "$content")

                if [ "$current_hash" != "$last_sent_hash" ]; then
                    local preview="${content:0:50}"
                    [ ${#content} -gt 50 ] && preview="${preview}..."
                    log "🔍 Local clipboard changed: '$preview' (${#content} bytes, hash: ${current_hash:0:8})"

                    # Update state
                    echo "$current_hash" > "$LAST_HASH_FILE"
                    echo "$content" > "$CLIPBOARD_CACHE"
                    last_sent_hash="$current_hash"

                    # Send to client
                    local encoded=$(echo -n "$content" | base64)
                    echo "CLIP:$encoded"
                    log "📤 Sent to client"
                fi
            fi
        fi

        sleep "$POLL_INTERVAL"
    done

    log "👋 Client disconnected"
}

# Export function for socat
export -f handle_client log get_clipboard set_clipboard get_clipboard_hash
export VERBOSE LOG_FILE STATE_DIR LAST_HASH_FILE CLIPBOARD_CACHE POLL_INTERVAL

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
        log "❌ Error: socat not found"
        log "   Install with: brew install socat"
        exit 1
    fi

    # Initialize clipboard cache
    local current_clip=$(get_clipboard)
    if [ -n "$current_clip" ]; then
        echo "$current_clip" > "$CLIPBOARD_CACHE"
        get_clipboard_hash "$current_clip" > "$LAST_HASH_FILE"
    fi

    # Start server using socat
    log "✓ Starting socat TCP server"
    socat -d -d \
        TCP-LISTEN:$PORT,reuseaddr,fork \
        EXEC:"/bin/bash -c handle_client",pty,stderr
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
