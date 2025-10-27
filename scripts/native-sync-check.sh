#!/usr/bin/env bash
# Health check and diagnostic tool for native clipboard sync

set -euo pipefail

# Configuration
SERVER_HOST="${NATIVE_SYNC_HOST:-10.211.55.2}"
SERVER_PORT="${NATIVE_SYNC_PORT:-9877}"
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

# Check macOS setup
check_macos() {
    echo "=== macOS Server Status ==="
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
        local pid=$(pgrep -f "native-sync-macos.sh")
        print_status ok "Process running (PID: $pid)"

        # Get process info
        local uptime=$(ps -p "$pid" -o etime= | xargs)
        print_status info "Uptime: $uptime"
    else
        print_status warn "Process not running"
        print_status info "Start with: ./scripts/native-sync-macos.sh start"
    fi

    # Check if port is listening
    if lsof -i ":$SERVER_PORT" -sTCP:LISTEN &> /dev/null 2>&1; then
        print_status ok "Server listening on port $SERVER_PORT"
        local listening_pid=$(lsof -ti ":$SERVER_PORT" -sTCP:LISTEN | head -1)
        print_status info "Listening PID: $listening_pid"
    else
        print_status error "Server not listening on port $SERVER_PORT"
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

    # Check for socat (recommended)
    if command -v socat &> /dev/null; then
        print_status ok "socat available (recommended)"
    else
        print_status warn "socat not found (install: brew install socat)"
    fi

    # Check log file
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

    # Check firewall
    echo
    print_status info "Firewall status:"
    if [ -f /usr/libexec/ApplicationFirewall/socketfilterfw ]; then
        local firewall_status=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || echo "unknown")
        echo "    $firewall_status"

        if /usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode 2>/dev/null | grep -q "enabled"; then
            print_status warn "Stealth mode enabled - may block connections"
            print_status info "Allow in: System Preferences → Firewall"
        fi
    fi

    # Network info
    echo
    print_status info "Network addresses (for client configuration):"
    ifconfig | grep -E "inet " | grep -v 127.0.0.1 | awk '{print "    " $2}'
}

# Check Linux/NixOS setup
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
        local pid=$(pgrep -f "native-sync-nixos.sh")
        print_status ok "Process running (PID: $pid)"

        # Get process info
        local uptime=$(ps -p "$pid" -o etime= | xargs)
        print_status info "Uptime: $uptime"
    else
        print_status warn "Process not running"
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

    # Check for socat (recommended)
    echo
    if command -v socat &> /dev/null; then
        print_status ok "socat available (recommended)"
    else
        print_status warn "socat not found (nc will be used as fallback)"
        print_status info "Install: nix-shell -p socat"
    fi

    # Check for nc
    if command -v nc &> /dev/null; then
        print_status ok "nc (netcat) available"
    else
        print_status error "nc (netcat) not found"
        print_status info "Install: nix-shell -p netcat"
    fi

    # Check server connectivity
    echo
    print_status info "Server connectivity:"
    echo "    Target: $SERVER_HOST:$SERVER_PORT"

    # Ping test
    if ping -c 1 -W 2 "$SERVER_HOST" &> /dev/null; then
        print_status ok "Host is reachable (ping)"
    else
        print_status error "Host is not reachable (ping failed)"
    fi

    # Port test
    if command -v nc &> /dev/null; then
        if timeout 2 nc -z "$SERVER_HOST" "$SERVER_PORT" 2>/dev/null; then
            print_status ok "Server port is open (TCP $SERVER_PORT)"
        else
            print_status error "Server port is not open (TCP $SERVER_PORT)"
            print_status info "Make sure server is running on macOS"
        fi
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

# Test clipboard sync
test_sync() {
    local os=$(detect_os)
    echo "=== Clipboard Sync Test ==="
    echo

    local test_string="native-sync-test-$(date +%s)"
    echo "Test string: $test_string"
    echo

    if [ "$os" = "macos" ]; then
        if command -v pbcopy &> /dev/null; then
            echo "$test_string" | pbcopy
            print_status ok "Written to macOS clipboard"
            echo
            print_status info "Check NixOS VM clipboard to verify sync"
            echo
            print_status info "Then copy something on NixOS and check macOS clipboard"
        else
            print_status error "pbcopy not available"
        fi
    elif [ "$os" = "linux" ]; then
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
            print_status info "Check macOS clipboard to verify sync"
            echo
            print_status info "Then copy something on macOS and check Linux clipboard"
        else
            print_status error "No clipboard tool available"
        fi
    else
        print_status error "Unknown OS: $os"
    fi
}

# Show help
show_help() {
    echo "Native Clipboard Sync - Health Check & Diagnostic Tool"
    echo
    echo "Usage: $0 [command]"
    echo
    echo "Commands:"
    echo "  check, status    - Show detailed status (default)"
    echo "  test            - Test clipboard sync with a test string"
    echo "  quick           - Quick status check"
    echo "  help            - Show this help"
    echo
    echo "Environment variables:"
    echo "  NATIVE_SYNC_HOST  - Server hostname/IP (default: 10.211.55.2)"
    echo "  NATIVE_SYNC_PORT  - Server port (default: 9877)"
    echo
}

# Quick check
quick_check() {
    local os=$(detect_os)

    if [ "$os" = "macos" ]; then
        echo "=== Quick Check (macOS) ==="
        if pgrep -f "native-sync-macos.sh" > /dev/null; then
            print_status ok "Server running"
        else
            print_status error "Server not running"
        fi

        if lsof -i ":$SERVER_PORT" -sTCP:LISTEN &> /dev/null 2>&1; then
            print_status ok "Listening on port $SERVER_PORT"
        else
            print_status error "Not listening"
        fi
    elif [ "$os" = "linux" ]; then
        echo "=== Quick Check (Linux) ==="
        if pgrep -f "native-sync-nixos.sh" > /dev/null; then
            print_status ok "Client running"
        else
            print_status error "Client not running"
        fi

        if timeout 1 nc -z "$SERVER_HOST" "$SERVER_PORT" 2>/dev/null; then
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
            if [ "$os" = "macos" ]; then
                check_macos
            elif [ "$os" = "linux" ]; then
                check_linux
            else
                echo "Unknown OS: $OSTYPE"
                exit 1
            fi
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
