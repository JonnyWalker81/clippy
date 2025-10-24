# Clippy Configuration Examples

This directory contains example configurations for different deployment scenarios.

## Files

- **`macos-server.toml`** - Configuration for macOS host running in server mode
- **`nixos-client.toml`** - Configuration for NixOS VM running in client mode
- **`both-modes.toml`** - Configuration for running both server and client

## Installation

### macOS Host (Server)

```bash
# Copy the example config
mkdir -p ~/.config/clippy
cp config.examples/macos-server.toml ~/.config/clippy/config.toml

# No changes needed - ready to use!
# Start the server
clippy start --server
```

### NixOS VM (Client)

```bash
# Copy the example config
mkdir -p ~/.config/clippy
cp config.examples/nixos-client.toml ~/.config/clippy/config.toml

# IMPORTANT: Edit the config to set your macOS host IP
nano ~/.config/clippy/config.toml
# Change: server_host = "10.211.55.2"  # to your actual macOS IP

# Start the client
clippy start --client
```

## Finding Your macOS Host IP

From the NixOS VM, run:

```bash
# Method 1: Check default gateway (most reliable)
ip route | grep default
# Look for the IP after "via" - usually 10.211.55.2 or 10.211.55.1

# Method 2: Try common Parallels IPs
ping -c 1 10.211.55.2  # Most common
ping -c 1 10.37.129.2  # Alternative

# Method 3: From macOS, find the Parallels network interface
# On macOS host, run:
ifconfig | grep -A 1 "vnic" | grep inet
```

## Configuration Options Explained

### Server Section

```toml
[server]
host = "0.0.0.0"    # Listen on all interfaces (required for VM access)
port = 9876         # TCP port for clipboard sync
auth_token = ""     # Optional authentication (recommended)
```

**Note**: Using `0.0.0.0` allows connections from any network interface, including the Parallels VM network.

### Client Section

```toml
[client]
server_host = "10.211.55.2"  # IP address of the server
server_port = 9876           # Must match server port
auto_connect = true          # Reconnect automatically
auth_token = ""              # Must match server if set
```

**Important**: `server_host` must be the IP address that the VM can reach the host on. This is typically the Parallels shared network gateway.

### Storage Section

```toml
[storage]
max_history = 1000            # Number of clipboard entries to keep
max_content_size_mb = 10      # Max size per clipboard item
database_path = ""            # Optional custom path
```

### Sync Section

```toml
[sync]
interval_ms = 500             # How often to check clipboard (milliseconds)
retry_delay_ms = 5000         # Wait before reconnecting after disconnect
heartbeat_interval_ms = 30000 # Keep-alive interval
```

**Performance tuning**:
- Lower `interval_ms` = faster sync but higher CPU usage
- Higher `interval_ms` = slower sync but lower CPU usage
- Recommended range: 300-1000ms

## Quick Setup (TL;DR)

### On macOS:
```bash
mkdir -p ~/.config/clippy
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

clippy start --server
```

### On NixOS:
```bash
mkdir -p ~/.config/clippy

# Find your macOS host IP
MACOS_IP=$(ip route | grep default | awk '{print $3}')
echo "Detected macOS host at: $MACOS_IP"

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

clippy start --client
```

## Testing the Configuration

### 1. Verify connectivity from NixOS VM:
```bash
# Test if you can reach the macOS host
ping -c 2 10.211.55.2  # Use your actual IP

# Test if port 9876 is open (after starting server on macOS)
nc -zv 10.211.55.2 9876
# or
telnet 10.211.55.2 9876
```

### 2. Start with verbose logging to debug:
```bash
# On macOS
clippy -v start --server

# On NixOS (in another terminal)
clippy -v start --client
```

### 3. Test clipboard sync:
```bash
# Copy text on macOS, paste on NixOS (or vice versa)
# Check the logs for "Detected clipboard change" messages
```

## Troubleshooting

### "Connection refused" error on NixOS client

**Problem**: Client can't connect to server

**Solutions**:
1. Verify server is running on macOS: `ps aux | grep clippy`
2. Check firewall on macOS (System Preferences → Firewall)
3. Verify correct IP in client config
4. Test connectivity: `telnet 10.211.55.2 9876`

### Clipboard not syncing

**Problem**: No errors but clipboard doesn't sync

**Solutions**:
1. Check clipboard permissions on macOS (Privacy settings)
2. Verify both processes are running
3. Increase logging: `clippy -v start`
4. Check if clipboard content is supported (text/images)

### High CPU usage

**Problem**: Clippy using too much CPU

**Solutions**:
1. Increase `interval_ms` to 1000 or higher
2. Reduce `max_history` if database is large
3. Check for clipboard change loops (same content bouncing)

## Security Notes

### Adding Authentication

For security, especially on shared networks:

1. Generate a token:
```bash
# Use a random string
openssl rand -base64 32
```

2. Add to both configs:
```toml
# On macOS server
[server]
auth_token = "your-generated-token"

# On NixOS client
[client]
auth_token = "your-generated-token"  # Must match!
```

### Firewall Configuration

**macOS**: Allow clippy through the firewall
- System Preferences → Security & Privacy → Firewall → Firewall Options
- Add clippy binary or allow port 9876

**NixOS**: If using host firewall, add to configuration.nix:
```nix
networking.firewall.allowedTCPPorts = [ 9876 ];
```
