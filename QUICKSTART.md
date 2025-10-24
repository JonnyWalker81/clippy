# Clippy Quick Start Guide

## Prerequisites

- Nix with flakes enabled
- Parallels VM running NixOS
- macOS host

## Setup (5 minutes)

### On macOS Host

```bash
# 1. Enter nix development environment
nix develop

# 2. Build the project
cargo build --release

# 3. Initialize configuration
./target/release/clippy config --init

# 4. Edit config if needed (optional)
# The default config should work for server mode
cat ~/.config/clippy/config.toml

# 5. Start the daemon in server mode
./target/release/clippy start --server
```

The macOS host will now be listening on `0.0.0.0:9876` for clipboard sync connections.

### On NixOS VM

```bash
# 1. Enter nix development environment
nix develop

# 2. Build the project
cargo build --release

# 3. Initialize configuration
./target/release/clippy config --init

# 4. Edit config to point to macOS host
# Find your macOS IP (usually 10.211.55.2 for Parallels)
nano ~/.config/clippy/config.toml
# Change client.server_host to your macOS IP:
# server_host = "10.211.55.2"

# 5. Start the daemon in client mode
./target/release/clippy start --client
```

## Testing the Sync

### Test 1: macOS → NixOS

1. On macOS, copy some text: "Hello from macOS!"
2. On NixOS, paste (Ctrl+V or Cmd+V)
3. You should see "Hello from macOS!"

### Test 2: NixOS → macOS

1. On NixOS, copy some text: "Hello from NixOS!"
2. On macOS, paste (Cmd+V)
3. You should see "Hello from NixOS!"

### Test 3: Image Sync

1. Take a screenshot or copy an image on macOS
2. Paste on NixOS - the image should appear
3. Works in reverse too!

## View Clipboard History

```bash
# Show last 20 clipboard entries
clippy history

# Show last 50 entries
clippy history --limit 50

# Filter by source
clippy history --source macos
clippy history --source nixos

# Search history
clippy search "password"

# View statistics
clippy stats
```

## Troubleshooting

### Can't Connect

1. **Check macOS IP:**
   ```bash
   # On macOS
   ifconfig | grep inet
   ```

2. **Verify server is running:**
   ```bash
   # On macOS
   ps aux | grep clippy
   ```

3. **Test network connectivity:**
   ```bash
   # On NixOS VM
   ping 10.211.55.2
   telnet 10.211.55.2 9876
   ```

4. **Check firewall:**
   ```bash
   # On macOS - allow port 9876 in System Preferences → Firewall
   ```

### Clipboard Not Syncing

1. **Check logs with verbose mode:**
   ```bash
   clippy -v start --server  # on macOS
   clippy -v start --client  # on NixOS
   ```

2. **Verify clipboard permissions:**
   - On macOS: System Preferences → Security & Privacy → Privacy → Accessibility

### Performance Issues

1. **Reduce polling frequency:**
   Edit `~/.config/clippy/config.toml`:
   ```toml
   [sync]
   interval_ms = 1000  # Check clipboard every 1 second instead of 500ms
   ```

## Running as a Service

### macOS (Auto-start on login)

See README.md section "Running as a Service" for launchd configuration.

### NixOS (systemd)

See README.md section "Running as a Service" for systemd configuration.

## Next Steps

- Set up auto-start services (see README.md)
- Configure authentication tokens for security
- Adjust history limits and sync intervals
- Explore the full CLI with `clippy --help`

## Getting Help

```bash
# Show all commands
clippy --help

# Show help for specific command
clippy start --help
clippy history --help
clippy search --help
```

For issues and feature requests, see the main README.md file.
