#!/usr/bin/env bash
# Comprehensive connection diagnostic tool

set -e

echo "=== Clippy Connection Diagnostics ==="
echo
echo "Run this on NixOS VM to diagnose connection issues"
echo

# Step 1: Find macOS host IP
echo "1. Finding macOS host IP addresses..."
GATEWAY_IP=$(ip route | grep default | awk '{print $3}')
echo "   Default gateway: $GATEWAY_IP"

# Try common Parallels IPs
POSSIBLE_IPS=("$GATEWAY_IP" "10.211.55.1" "10.211.55.2" "10.37.129.1" "10.37.129.2")
echo "   Possible macOS IPs to test:"
for ip in "${POSSIBLE_IPS[@]}"; do
    echo "   - $ip"
done
echo

# Step 2: Test ICMP connectivity
echo "2. Testing ICMP (ping) connectivity..."
REACHABLE_IPS=()
for ip in "${POSSIBLE_IPS[@]}"; do
    echo -n "   Testing $ip... "
    if ping -c 1 -W 2 "$ip" &> /dev/null; then
        echo "✓ REACHABLE"
        REACHABLE_IPS+=("$ip")
    else
        echo "✗ NOT REACHABLE"
    fi
done
echo

if [ ${#REACHABLE_IPS[@]} -eq 0 ]; then
    echo "❌ Cannot reach any potential macOS host IPs"
    echo "   Network issue - check VM network settings"
    exit 1
fi

# Step 3: Test TCP port 9876
echo "3. Testing TCP port 9876 on reachable IPs..."
OPEN_SERVERS=()
for ip in "${REACHABLE_IPS[@]}"; do
    echo -n "   Testing $ip:9876... "
    if timeout 2 bash -c "cat < /dev/null > /dev/tcp/$ip/9876" 2>/dev/null; then
        echo "✓ PORT OPEN - SERVER FOUND!"
        OPEN_SERVERS+=("$ip")
    else
        echo "✗ Connection refused"
    fi
done
echo

if [ ${#OPEN_SERVERS[@]} -eq 0 ]; then
    echo "❌ No clippy server found on port 9876"
    echo
    echo "Possible causes:"
    echo "  1. Server not running on macOS"
    echo "  2. Server bound to 127.0.0.1 instead of 0.0.0.0"
    echo "  3. macOS firewall blocking port 9876"
    echo "  4. Server using different port"
    echo
    echo "On macOS host, verify server is running:"
    echo "  ps aux | grep clippy"
    echo "  lsof -i :9876"
    echo "  netstat -an | grep 9876"
    echo
    echo "Check server config on macOS:"
    echo "  cat ~/.config/clippy/config.toml"
    echo "  Should show: host = \"0.0.0.0\"  # NOT 127.0.0.1"
    echo
    exit 1
fi

# Step 4: Success - provide config
echo "✓ Found clippy server(s) at:"
for ip in "${OPEN_SERVERS[@]}"; do
    echo "  - $ip:9876"
done
echo

BEST_IP="${OPEN_SERVERS[0]}"
echo "4. Recommended configuration:"
echo
echo "Update ~/.config/clippy/config.toml:"
cat << EOF
[server]
host = "0.0.0.0"
port = 9876

[client]
server_host = "$BEST_IP"
server_port = 9876
auto_connect = true

[storage]
max_history = 1000
max_content_size_mb = 10

[sync]
interval_ms = 500
retry_delay_ms = 5000
heartbeat_interval_ms = 30000
EOF
echo

# Step 5: Apply fix?
read -p "Apply this configuration now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    mkdir -p ~/.config/clippy
    cat > ~/.config/clippy/config.toml << EOF
[server]
host = "0.0.0.0"
port = 9876

[client]
server_host = "$BEST_IP"
server_port = 9876
auto_connect = true

[storage]
max_history = 1000
max_content_size_mb = 10

[sync]
interval_ms = 500
retry_delay_ms = 5000
heartbeat_interval_ms = 30000
EOF
    echo "✓ Configuration updated!"
    echo
    echo "Now run: clippy start --client"
else
    echo "Configuration not changed."
fi
