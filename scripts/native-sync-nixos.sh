#!/usr/bin/env bash
# Native clipboard sync for NixOS/Linux (Client Mode)
# Bidirectional clipboard sync using xclip/xsel/wl-clipboard and TCP sockets

set -euo pipefail

# Configuration
SERVER_HOST="${NATIVE_SYNC_HOST:-10.211.55.2}"
SERVER_PORT="${NATIVE_SYNC_PORT:-9877}"
POLL_INTERVAL="${NATIVE_SYNC_INTERVAL:-0.2}"  # 200ms
VERBOSE="${NATIVE_SYNC_VERBOSE:-1}"
LOG_FILE="${NATIVE_SYNC_LOG:-/tmp/native-sync-nixos.log}"

# State file to track last clipboard
STATE_DIR="/tmp/native-sync-$$"
mkdir -p "$STATE_DIR"
LAST_HASH_FILE="$STATE_DIR/last_hash"
CLIPBOARD_CACHE="$STATE_DIR/clipboard_cache"
SERVER_PIPE="$STATE_DIR/server_pipe"

# Clipboard tool selection
CLIPBOARD_TOOL=""
CLIPBOARD_READ_CMD=""
CLIPBOARD_WRITE_CMD=""

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
        for target in STRING UTF8_STRING TEXT text/plain; do
            content=$(xclip -o -selection clipboard -t "$target" 2>/dev/null || echo "")
            if [ -n "$content" ]; then
                echo "$content"
                return 0
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

                # Send to server if pipe exists
                if [ -p "$SERVER_PIPE" ]; then
                    local encoded=$(echo -n "$content" | base64 -w 0)
                    echo "CLIP:$encoded" >> "$SERVER_PIPE"
                    log "📤 Sent to server: '$preview'"
                fi
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

# Connect to server and handle communication
connect_to_server() {
    log "🔗 Connecting to server at $SERVER_HOST:$SERVER_PORT"

    # Create named pipe for sending to server
    mkfifo "$SERVER_PIPE" 2>/dev/null || true

    # Start clipboard monitor in background
    monitor_clipboard &
    local monitor_pid=$!

    # Connect and handle bidirectional communication
    while true; do
        if command -v socat &> /dev/null; then
            log "✓ Using socat for connection"
            # Use socat for bidirectional communication
            # Read from server_pipe and send, receive and process
            socat -d -d - TCP:$SERVER_HOST:$SERVER_PORT,retry=5,interval=2 < "$SERVER_PIPE" | while IFS= read -r line; do
                handle_server_message "$line"
            done
        elif command -v nc &> /dev/null; then
            log "✓ Using nc for connection (fallback)"
            # Fallback to nc
            nc "$SERVER_HOST" "$SERVER_PORT" < "$SERVER_PIPE" | while IFS= read -r line; do
                handle_server_message "$line"
            done
        else
            log "❌ Error: Neither socat nor nc found"
            exit 1
        fi

        log "⚠️  Disconnected from server, reconnecting in 5 seconds..."
        sleep 5
    done
}

# Handle messages from server
handle_server_message() {
    local line="$1"

    if [[ "$line" =~ ^CLIP:(.+)$ ]]; then
        local encoded="${BASH_REMATCH[1]}"
        local content=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")

        if [ -n "$content" ]; then
            local hash=$(get_clipboard_hash "$content")
            local preview="${content:0:50}"
            [ ${#content} -gt 50 ] && preview="${preview}..."

            log "📥 Received from server: '$preview' (${#content} bytes, hash: ${hash:0:8})"

            # Check if this is different from what we last sent
            local last_hash=""
            if [ -f "$LAST_HASH_FILE" ]; then
                last_hash=$(cat "$LAST_HASH_FILE")
            fi

            if [ "$hash" != "$last_hash" ]; then
                # Apply to local clipboard
                if set_clipboard "$content"; then
                    echo "$hash" > "$LAST_HASH_FILE"
                    echo "$content" > "$CLIPBOARD_CACHE"
                    log "✅ Applied to local clipboard"
                else
                    log "❌ Failed to apply to clipboard"
                fi
            else
                log "⏭️  Skipping (same as last sent clipboard)"
            fi
        fi
    elif [[ "$line" =~ ^ACK:(.+)$ ]]; then
        local hash="${BASH_REMATCH[1]}"
        log "✅ Server acknowledged: ${hash:0:8}"
    elif [[ "$line" == "NAK" ]]; then
        log "❌ Server rejected clipboard update"
    elif [[ "$line" == "PONG" ]]; then
        log "💓 Server alive"
    fi
}

# Health check mode
health_check() {
    echo "=== Native Sync Health Check (NixOS) ==="
    echo

    # Check if process is running
    if pgrep -f "native-sync-nixos.sh" > /dev/null; then
        echo "✓ Native sync is running (PID: $(pgrep -f 'native-sync-nixos.sh'))"
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
    if command -v nc &> /dev/null; then
        if timeout 2 nc -z "$SERVER_HOST" "$SERVER_PORT" 2>/dev/null; then
            echo "✓ Server reachable at $SERVER_HOST:$SERVER_PORT"
        else
            echo "✗ Cannot reach server at $SERVER_HOST:$SERVER_PORT"
        fi
    else
        echo "⚠️  Cannot test connectivity (nc not found)"
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

# Ping server
ping_server() {
    log "🏓 Pinging server at $SERVER_HOST:$SERVER_PORT"

    if command -v nc &> /dev/null; then
        if echo "PING" | nc -w 2 "$SERVER_HOST" "$SERVER_PORT" | grep -q "PONG"; then
            log "✅ Server responded with PONG"
            return 0
        else
            log "❌ No PONG received from server"
            return 1
        fi
    else
        log "❌ nc not available for ping"
        return 1
    fi
}

# Parse arguments
case "${1:-start}" in
    start)
        if ! detect_clipboard_tool; then
            exit 1
        fi
        connect_to_server
        ;;
    check|status|health)
        health_check
        ;;
    ping)
        ping_server
        ;;
    stop)
        log "🛑 Stopping native sync..."
        pkill -f "native-sync-nixos.sh" || echo "No process found"
        ;;
    *)
        echo "Usage: $0 {start|stop|check|health|status|ping}"
        echo
        echo "Environment variables:"
        echo "  NATIVE_SYNC_HOST       - Server hostname/IP (default: 10.211.55.2)"
        echo "  NATIVE_SYNC_PORT       - Server port (default: 9877)"
        echo "  NATIVE_SYNC_INTERVAL   - Poll interval in seconds (default: 0.2)"
        echo "  NATIVE_SYNC_VERBOSE    - Enable verbose output (default: 1)"
        echo "  NATIVE_SYNC_LOG        - Log file path (default: /tmp/native-sync-nixos.log)"
        exit 1
        ;;
esac
