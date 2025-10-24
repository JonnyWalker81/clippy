#!/usr/bin/env bash
# Setup script for macOS host (server mode)

set -e

echo "=== Clippy macOS Host Setup ==="
echo

# Create config directory
echo "1. Creating configuration..."
mkdir -p ~/.config/clippy

# Create config file
cat > ~/.config/clippy/config.toml << 'EOF'
[server]
host = "0.0.0.0"
port = 9876

[client]
server_host = "127.0.0.1"
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

echo "   ✓ Config created at ~/.config/clippy/config.toml"
echo

# Find IP addresses
echo "2. Your macOS IP addresses:"
echo "   (Share these with your NixOS VM for client configuration)"
echo
ifconfig | grep -E "inet " | grep -v 127.0.0.1 | awk '{print "   " $2}'
echo

# Check firewall
echo "3. Firewall check:"
if [ -f /usr/libexec/ApplicationFirewall/socketfilterfw ]; then
    if /usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode | grep -q "enabled"; then
        echo "   ⚠ Firewall is in stealth mode"
        echo "   You may need to allow clippy in System Preferences → Firewall"
    else
        echo "   ✓ Firewall not in stealth mode"
    fi
fi
echo

echo "4. Setup complete!"
echo
echo "✓ Ready to start! Run:"
echo "  clippy start --server"
echo
echo "Then on your NixOS VM, configure client to connect to one of the IPs above"
echo
