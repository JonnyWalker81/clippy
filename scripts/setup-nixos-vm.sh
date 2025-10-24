#!/usr/bin/env bash
# Setup script for NixOS VM (client mode)

set -e

echo "=== Clippy NixOS VM Setup ==="
echo

# Find macOS host IP
echo "1. Detecting macOS host IP..."
MACOS_IP=$(ip route | grep default | awk '{print $3}')

if [ -z "$MACOS_IP" ]; then
    echo "❌ Could not detect macOS host IP automatically"
    echo "   Please enter it manually (usually 10.211.55.1 or 10.211.55.2):"
    read -r MACOS_IP
fi

echo "   Detected macOS host: $MACOS_IP"
echo

# Test connectivity
echo "2. Testing connectivity to macOS host..."
if ping -c 1 -W 2 "$MACOS_IP" &> /dev/null; then
    echo "   ✓ Can reach macOS host"
else
    echo "   ❌ Cannot reach macOS host at $MACOS_IP"
    echo "   Please check network configuration"
    exit 1
fi
echo

# Check if server is running on macOS
echo "3. Checking if clippy server is running on macOS..."
if timeout 2 bash -c "cat < /dev/null > /dev/tcp/$MACOS_IP/9876" 2>/dev/null; then
    echo "   ✓ Server is running on macOS:9876"
    SERVER_RUNNING=true
else
    echo "   ⚠ Server is NOT running on macOS:9876"
    echo "   You need to start the server on macOS first:"
    echo "   >>> clippy start --server"
    echo
    read -p "   Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    SERVER_RUNNING=false
fi
echo

# Create config directory
echo "4. Creating configuration..."
mkdir -p ~/.config/clippy

# Create config file
cat > ~/.config/clippy/config.toml << EOF
[server]
host = "0.0.0.0"
port = 9876

[client]
server_host = "$MACOS_IP"
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
echo "   Server host: $MACOS_IP:9876"
echo

# Show next steps
echo "5. Setup complete!"
echo
if [ "$SERVER_RUNNING" = true ]; then
    echo "✓ Ready to start! Run:"
    echo "  clippy start --client"
else
    echo "⚠ Next steps:"
    echo "  1. On macOS host, run: clippy start --server"
    echo "  2. On this NixOS VM, run: clippy start --client"
fi
echo
echo "For testing locally on NixOS only (no macOS sync):"
echo "  clippy start --server"
echo
