#!/usr/bin/env bash
# Health check and diagnostic tool for HTTP-based clipboard sync

set -euo pipefail

# Configuration
SERVER_URL="${CLIPBOARD_SERVER_URL:-http://localhost:8080}"
NIXOS_SERVER_URL="${CLIPBOARD_SERVER_URL:-http://10.211.55.2:8080}"
LOG_FILE_MACOS="/tmp/native-sync-macos.log"
LOG_FILE_NIXOS="/tmp/native-sync-nixos.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

# Print colored status
print_status() {
    local status="$1"
    local message="$2"

    case "$status" in
        ok|success|yes)
            echo -e "${GREEN}✓${NC} $message"
            ;;
        warn|warning)
            echo -e "${YELLOW}⚠${NC} $message"
            ;;
        error|fail|no)
            echo -e "${RED}✗${NC} $message"
            ;;
        info)
            echo -e "  $message"
            ;;
    esac
}

# Parse JSON value (simple extraction without jq dependency)
json_value() {
    local key="$1"
    local json="$2"
    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[^,}]*" | sed 's/.*:[[:space:]]*//' | tr -d '"'
}

# Check server
check_server() {
    local server_url="$1"
    echo "=== Clipboard HTTP Server Status ==="
    echo

    # Check if clipboard_server binary exists
    if [ -f "target/debug/clipboard_server" ] || [ -f "target/release/clipboard_server" ]; then
        print_status ok "Server binary found"
    else
        print_status warn "Server binary not found (run: cargo build --bin clipboard_server)"
    fi

    # Check if server process is running
    if pgrep -f "clipboard_server" > /dev/null; then
        local pid=$(pgrep -f "clipboard_server" | head -1)
        print_status ok "Server running (PID: $pid)"

        # Get process info
        local uptime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs || echo "unknown")
        print_status info "Uptime: $uptime"
    else
        print_status warn "Server not running"
        print_status info "Start with: cargo run --bin clipboard_server"
        return
    fi

    # Check server health endpoint
    if command -v curl &> /dev/null; then
        if curl -s -f "$server_url/health" > /dev/null 2>&1; then
            print_status ok "Server responding at $server_url"

            # Get health details
            local health=$(curl -s "$server_url/health" 2>/dev/null)
            if [ -n "$health" ]; then
                local status=$(json_value "status" "$health")
                local items=$(json_value "items_count" "$health")
                local uptime=$(json_value "uptime_seconds" "$health")
                print_status info "Status: $status"
                print_status info "Items in history: $items"
                print_status info "Server uptime: ${uptime}s"
            fi

            # Test GET endpoint
            if curl -s "$server_url/api/clipboard/latest" > /dev/null 2>&1; then
                print_status ok "GET /api/clipboard/latest working"
            else
                print_status info "No clipboard items yet (expected on first run)"
            fi

            # List API endpoints
            echo
            print_status info "Available endpoints:"
            echo "    GET  $server_url/health"
            echo "    POST $server_url/api/clipboard"
            echo "    GET  $server_url/api/clipboard/latest"
            echo "    GET  $server_url/api/clipboard/history"
        else
            print_status error "Cannot reach server at $server_url"
            print_status info "Check if server is running and firewall allows connections"
        fi
    else
        print_status error "curl not available for testing"
    fi

    # Network info for clients
    echo
    print_status info "Server URL for clients:"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "    Local:  http://localhost:8080"
        echo "    VM:     http://$(ifconfig | grep "inet " | grep -v 127.0.0.1 | head -1 | awk '{print $2}'):8080"
    else
        echo "    $server_url"
    fi
}

# Check macOS client
check_macos() {
    echo "=== macOS Client Status ==="
    echo

    # Check if script exists
    if [ -f "scripts/native-sync-macos.sh" ]; then
        print_status ok "Script found: scripts/native-sync-macos.sh"
    else
        print_status error "Script not found: scripts/native-sync-macos.sh"
        return
    fi

    # Check if running
    if pgrep -f "native-sync-macos.sh" > /dev/null; then
        local pid=$(pgrep -f "native-sync-macos.sh" | head -1)
        print_status ok "Client running (PID: $pid)"

        # Get process info
        local uptime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs || echo "unknown")
        print_status info "Uptime: $uptime"
    else
        print_status warn "Client not running"
        print_status info "Start with: ./scripts/native-sync-macos.sh start"
    fi

    # Check clipboard tools
    if command -v pbcopy &> /dev/null && command -v pbpaste &> /dev/null; then
        print_status ok "Clipboard tools available (pbcopy/pbpaste)"

        # Try to read clipboard
        local clipboard_content=$(pbpaste 2>/dev/null | head -c 100 || echo "")
        if [ -n "$clipboard_content" ]; then
            local preview="${clipboard_content:0:50}"
            [ ${#clipboard_content} -gt 50 ] && preview="${preview}..."
            print_status info "Current clipboard: '$preview'"
        else
            print_status info "Current clipboard: (empty)"
        fi
    else
        print_status error "Clipboard tools not available"
    fi

    # Check curl
    if command -v curl &> /dev/null; then
        print_status ok "curl available"
    else
        print_status error "curl not found"
    fi

    # Check server connectivity
    echo
    print_status info "Server connectivity:"
    if curl -s -f "$SERVER_URL/health" > /dev/null 2>&1; then
        print_status ok "Can reach server at $SERVER_URL"
    else
        print_status error "Cannot reach server at $SERVER_URL"
    fi

    # Check log file
    echo
    if [ -f "$LOG_FILE_MACOS" ]; then
        print_status ok "Log file exists: $LOG_FILE_MACOS"
        local log_size=$(du -h "$LOG_FILE_MACOS" | cut -f1)
        print_status info "Log size: $log_size"
        echo
        print_status info "Last 3 log entries:"
        tail -3 "$LOG_FILE_MACOS" | sed 's/^/    /'
    else
        print_status warn "No log file found at $LOG_FILE_MACOS"
    fi
}

# Check Linux/NixOS client
check_linux() {
    echo "=== NixOS/Linux Client Status ==="
    echo

    # Check if script exists
    if [ -f "scripts/native-sync-nixos.sh" ]; then
        print_status ok "Script found: scripts/native-sync-nixos.sh"
    else
        print_status error "Script not found: scripts/native-sync-nixos.sh"
        return
    fi

    # Check if running
    if pgrep -f "native-sync-nixos.sh" > /dev/null; then
        local pid=$(pgrep -f "native-sync-nixos.sh" | head -1)
        print_status ok "Client running (PID: $pid)"

        # Get process info
        local uptime=$(ps -p "$pid" -o etime= | xargs)
        print_status info "Uptime: $uptime"
    else
        print_status warn "Client not running"
        print_status info "Start with: ./scripts/native-sync-nixos.sh start"
    fi

    # Check environment
    echo
    print_status info "Display environment:"
    echo "    DISPLAY: ${DISPLAY:-<not set>}"
    echo "    WAYLAND_DISPLAY: ${WAYLAND_DISPLAY:-<not set>}"
    echo "    XDG_SESSION_TYPE: ${XDG_SESSION_TYPE:-<not set>}"

    # Check clipboard tools
    echo
    local clipboard_tool=""
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        if command -v wl-paste &> /dev/null && command -v wl-copy &> /dev/null; then
            clipboard_tool="wayland"
            print_status ok "Wayland clipboard available (wl-clipboard)"
        else
            print_status error "Wayland detected but wl-clipboard not found"
            print_status info "Install: nix-shell -p wl-clipboard"
        fi
    elif [ -n "${DISPLAY:-}" ]; then
        if command -v xclip &> /dev/null; then
            clipboard_tool="xclip"
            print_status ok "X11 clipboard available (xclip)"
        elif command -v xsel &> /dev/null; then
            clipboard_tool="xsel"
            print_status ok "X11 clipboard available (xsel)"
        else
            print_status error "X11 detected but no clipboard tool found"
            print_status info "Install: nix-shell -p xclip"
        fi
    else
        print_status error "No display server detected"
    fi

    # Try to read clipboard
    if [ -n "$clipboard_tool" ]; then
        local clipboard_content=""
        case "$clipboard_tool" in
            wayland)
                clipboard_content=$(wl-paste -n 2>/dev/null | head -c 100 || echo "")
                ;;
            xclip)
                clipboard_content=$(xclip -o -selection clipboard 2>/dev/null | head -c 100 || echo "")
                ;;
            xsel)
                clipboard_content=$(xsel --clipboard --output 2>/dev/null | head -c 100 || echo "")
                ;;
        esac

        if [ -n "$clipboard_content" ]; then
            local preview="${clipboard_content:0:50}"
            [ ${#clipboard_content} -gt 50 ] && preview="${preview}..."
            print_status info "Current clipboard: '$preview'"
        else
            print_status info "Current clipboard: (empty)"
        fi
    fi

    # Check curl
    echo
    if command -v curl &> /dev/null; then
        print_status ok "curl available"
    else
        print_status error "curl not found"
        print_status info "Install: nix-shell -p curl"
    fi

    # Check server connectivity
    echo
    print_status info "Server connectivity:"
    echo "    Target: $NIXOS_SERVER_URL"

    # Extract host from URL
    local host=$(echo "$NIXOS_SERVER_URL" | sed 's|http://||' | sed 's|:.*||')

    # Ping test
    if ping -c 1 -W 2 "$host" &> /dev/null; then
        print_status ok "Host is reachable (ping)"
    else
        print_status error "Host is not reachable (ping failed)"
    fi

    # HTTP test
    if curl -s -f "$NIXOS_SERVER_URL/health" > /dev/null 2>&1; then
        print_status ok "Server is reachable (HTTP)"

        # Get server health
        local health=$(curl -s "$NIXOS_SERVER_URL/health" 2>/dev/null)
        if [ -n "$health" ]; then
            local items=$(json_value "items_count" "$health")
            local uptime=$(json_value "uptime_seconds" "$health")
            print_status info "Server items: $items"
            print_status info "Server uptime: ${uptime}s"
        fi
    else
        print_status error "Server is not reachable (HTTP)"
        print_status info "Make sure clipboard_server is running on the host"
    fi

    # Check log file
    echo
    if [ -f "$LOG_FILE_NIXOS" ]; then
        print_status ok "Log file exists: $LOG_FILE_NIXOS"
        local log_size=$(du -h "$LOG_FILE_NIXOS" | cut -f1)
        print_status info "Log size: $log_size"
        echo
        print_status info "Last 3 log entries:"
        tail -3 "$LOG_FILE_NIXOS" | sed 's/^/    /'
    else
        print_status warn "No log file found at $LOG_FILE_NIXOS"
    fi
}

# Test clipboard sync with HTTP server
test_sync() {
    local os=$(detect_os)
    echo "=== Clipboard Sync Test (HTTP) ==="
    echo

    local test_string="http-sync-test-$(date +%s)"
    echo "Test string: $test_string"
    echo

    if [ "$os" = "macos" ]; then
        # Test on macOS
        if command -v pbcopy &> /dev/null; then
            echo "$test_string" | pbcopy
            print_status ok "Written to macOS clipboard"
            echo
            print_status info "Check server history:"
            echo "    curl $SERVER_URL/api/clipboard/history | jq"
            echo
            print_status info "Check NixOS VM clipboard to verify sync"
        else
            print_status error "pbcopy not available"
        fi
    elif [ "$os" = "linux" ]; then
        # Test on Linux
        local wrote=false
        if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy &> /dev/null; then
            echo "$test_string" | wl-copy
            wrote=true
        elif [ -n "${DISPLAY:-}" ] && command -v xclip &> /dev/null; then
            echo "$test_string" | xclip -selection clipboard
            wrote=true
        elif [ -n "${DISPLAY:-}" ] && command -v xsel &> /dev/null; then
            echo "$test_string" | xsel --clipboard --input
            wrote=true
        fi

        if [ "$wrote" = true ]; then
            print_status ok "Written to Linux clipboard"
            echo
            print_status info "Check server history:"
            echo "    curl $NIXOS_SERVER_URL/api/clipboard/history | jq"
            echo
            print_status info "Check macOS clipboard to verify sync"
        else
            print_status error "No clipboard tool available"
        fi
    else
        print_status error "Unknown OS: $os"
    fi

    echo
    print_status info "Manual test commands:"
    echo "    # Post clipboard"
    echo "    curl -X POST $SERVER_URL/api/clipboard -H 'Content-Type: application/json' -d '{\"content\":\"SGVsbG8gV29ybGQ=\"}'"
    echo
    echo "    # Get latest"
    echo "    curl $SERVER_URL/api/clipboard/latest"
    echo
    echo "    # View history"
    echo "    curl $SERVER_URL/api/clipboard/history"
}

# Show help
show_help() {
    echo "HTTP-Based Clipboard Sync - Health Check & Diagnostic Tool"
    echo
    echo "Usage: $0 [command]"
    echo
    echo "Commands:"
    echo "  check, status    - Show detailed status (default)"
    echo "  server           - Check only the HTTP server"
    echo "  test             - Test clipboard sync"
    echo "  quick            - Quick status check"
    echo "  help             - Show this help"
    echo
    echo "Environment variables:"
    echo "  CLIPBOARD_SERVER_URL  - Server URL (default: http://localhost:8080 or http://10.211.55.2:8080)"
    echo
}

# Quick check
quick_check() {
    local os=$(detect_os)

    echo "=== Quick Check ==="

    # Check server
    if pgrep -f "clipboard_server" > /dev/null; then
        print_status ok "Server running"
    else
        print_status error "Server not running"
    fi

    if [ "$os" = "macos" ]; then
        if pgrep -f "native-sync-macos.sh" > /dev/null; then
            print_status ok "macOS client running"
        else
            print_status error "macOS client not running"
        fi

        if curl -s -f "$SERVER_URL/health" > /dev/null 2>&1; then
            print_status ok "Server reachable"
        else
            print_status error "Server not reachable"
        fi
    elif [ "$os" = "linux" ]; then
        if pgrep -f "native-sync-nixos.sh" > /dev/null; then
            print_status ok "Linux client running"
        else
            print_status error "Linux client not running"
        fi

        if curl -s -f "$NIXOS_SERVER_URL/health" > /dev/null 2>&1; then
            print_status ok "Server reachable"
        else
            print_status error "Server not reachable"
        fi
    fi
}

# Main
main() {
    local command="${1:-check}"

    case "$command" in
        check|status)
            local os=$(detect_os)
            check_server "${SERVER_URL}"
            echo
            echo
            if [ "$os" = "macos" ]; then
                check_macos
            elif [ "$os" = "linux" ]; then
                check_linux
            else
                echo "Unknown OS: $OSTYPE"
                exit 1
            fi
            ;;
        server)
            check_server "${SERVER_URL}"
            ;;
        test)
            test_sync
            ;;
        quick)
            quick_check
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            echo "Unknown command: $command"
            echo
            show_help
            exit 1
            ;;
    esac
}

main "$@"
