# Clippy Troubleshooting Guide

## Error: "Connection refused (os error 111)"

### Symptoms
```
ERROR Client error: Connection refused (os error 111)
INFO Reconnecting in 5000 ms...
```

### Cause
The clippy client is trying to connect to a server that isn't running or isn't reachable.

### Solutions

#### Solution 1: Quick Fix - Run in Server-Only Mode
If you just want to use clipboard history locally without syncing:

```bash
# Stop the current process
pkill clippy  # or press Ctrl+C

# Run in server-only mode
clippy start --server
```

This will:
- ✓ Monitor your local clipboard
- ✓ Save clipboard history
- ✓ Allow you to query history with `clippy history`
- ✗ Will NOT sync with macOS host

#### Solution 2: Proper Setup for macOS ↔ NixOS Sync

**Step 1: Start Server on macOS Host**

```bash
# On macOS host
cd /path/to/clippy
nix develop
cargo build --release

# Setup config
./scripts/setup-macos-host.sh
# Or manually:
mkdir -p ~/.config/clippy
cp config.examples/macos-server.toml ~/.config/clippy/config.toml

# Start server
./target/release/clippy start --server
```

**Step 2: Configure and Start Client on NixOS VM**

```bash
# On NixOS VM
./scripts/setup-nixos-vm.sh
# Or manually update config with macOS IP

# Start client
clippy start --client
```

#### Solution 3: Change Config to Point to Localhost
If you want to test on a single machine:

```bash
# Edit config
nano ~/.config/clippy/config.toml

# Change client section:
[client]
server_host = "127.0.0.1"  # Instead of 10.211.55.1
server_port = 9876
auto_connect = true

# Restart
clippy start  # Will run both server and client, connecting to itself
```

### Diagnostic Steps

#### 1. Check if you're running the right mode

```bash
# Check what's running
ps aux | grep clippy

# You should see either:
# - "clippy start --server" on macOS
# - "clippy start --client" on NixOS
# - "clippy start" (both modes) on either
```

#### 2. Verify network connectivity

```bash
# On NixOS VM, check if you can reach macOS host
ping -c 2 10.211.55.1  # Use your actual macOS IP

# Find your macOS host IP
ip route | grep default
```

#### 3. Check if port 9876 is open

```bash
# On NixOS VM, test connection to macOS server
nc -zv 10.211.55.1 9876
# or
telnet 10.211.55.1 9876

# Should see "Connection succeeded" or similar
```

#### 4. Check your config

```bash
# View current config
clippy config --show

# Check what IP the client is trying to connect to
grep server_host ~/.config/clippy/config.toml
```

#### 5. Check macOS firewall

On macOS:
1. System Preferences → Security & Privacy → Firewall
2. Click "Firewall Options"
3. Ensure clippy is allowed, or temporarily disable firewall to test

#### 6. Run with verbose logging

```bash
# See detailed connection attempts
clippy -v start --client

# On macOS
clippy -v start --server
```

## Error: "Authentication failed"

### Symptoms
```
ERROR Authentication failed: ...
```

### Cause
Client and server have mismatched `auth_token` values.

### Solution
Ensure both configs have the same token (or both have none):

```bash
# On both macOS and NixOS, edit config
nano ~/.config/clippy/config.toml

# Either remove auth_token entirely, or set the same value:
[server]
auth_token = "same-secret-token"

[client]
auth_token = "same-secret-token"  # Must match server!
```

## Error: "Address already in use"

### Symptoms
```
ERROR Failed to bind to 0.0.0.0:9876: Address already in use
```

### Cause
Another clippy instance (or another program) is using port 9876.

### Solution

#### Check what's using the port
```bash
# Linux/macOS
lsof -i :9876
# or
netstat -tulpn | grep 9876

# Kill the process
kill <PID>
```

#### Use a different port
```bash
# Edit config
nano ~/.config/clippy/config.toml

# Change port on BOTH server and client:
[server]
port = 9877  # New port

[client]
server_port = 9877  # Must match server!
```

## Clipboard Not Syncing

### Symptoms
- No errors
- Processes running
- But clipboard doesn't sync

### Diagnostic Steps

#### 1. Check if clipboard changes are detected

```bash
# Run with verbose logging
clippy -v start --server

# Copy something
# You should see: "Detected clipboard change"
```

#### 2. Verify clipboard permissions

**macOS:**
- System Preferences → Security & Privacy → Privacy → Accessibility
- Ensure Terminal (or your terminal app) has access

**NixOS/Linux:**
- Check if xclip or wl-clipboard is working
- Test: `echo "test" | xclip -selection clipboard`

#### 3. Check content type support

Currently supported:
- ✓ Plain text
- ✓ Images (PNG, JPEG)
- ✓ HTML

Not yet supported:
- ✗ Files/file paths
- ✗ Some proprietary formats

#### 4. Check polling interval

```bash
# View current interval
grep interval_ms ~/.config/clippy/config.toml

# For faster detection, decrease interval:
[sync]
interval_ms = 200  # Check every 200ms instead of 500ms
```

#### 5. Test with simple text

```bash
# Copy simple text
echo "test123" | pbcopy  # macOS
# or
echo "test123" | xclip -selection clipboard  # Linux

# Check if it appears in history
clippy history --limit 5
```

## High CPU Usage

### Cause
Polling clipboard too frequently or large history.

### Solution

#### Increase polling interval
```bash
# Edit config
nano ~/.config/clippy/config.toml

[sync]
interval_ms = 1000  # Check every 1 second instead of 500ms
```

#### Reduce history size
```bash
# Edit config
[storage]
max_history = 100  # Keep fewer entries

# Clear existing large history
clippy clear --yes
```

## Database Errors

### Symptoms
```
ERROR Failed to insert clipboard entry: ...
```

### Solution

#### Reset database
```bash
# Find database location
clippy stats

# Remove database (backs up history first!)
mv ~/.local/share/clippy/clipboard.db ~/.local/share/clippy/clipboard.db.backup

# Restart clippy (will create new database)
clippy start --server
```

## Getting Help

### Collect diagnostic information

```bash
# Check version
clippy --version

# Check config
clippy config --show

# Check stats
clippy stats

# Check system info
uname -a
rustc --version

# Test connectivity
ping -c 2 <macos-ip>
nc -zv <macos-ip> 9876
```

### Enable debug logging

```bash
# Set Rust log level
RUST_LOG=debug clippy -v start --server
```

### Common Command Reference

```bash
# Start modes
clippy start --server    # Server only (on macOS)
clippy start --client    # Client only (on NixOS)
clippy start            # Both modes

# View history
clippy history
clippy history --limit 50
clippy history --source macos
clippy search "keyword"

# Manage
clippy stats
clippy clear
clippy config --show

# Debug
clippy -v start --server  # Verbose logging
```
