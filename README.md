# Clippy - Cross-Platform Clipboard Synchronization

A Rust-based clipboard synchronization tool that seamlessly syncs clipboard content between a NixOS VM (running in Parallels) and macOS host. Features include real-time bidirectional sync, persistent clipboard history with SQLite storage, and a CLI for querying history.

## Features

- **Bidirectional Clipboard Sync**: Copy on NixOS VM → Paste on macOS, and vice versa
- **Real-time Synchronization**: Sub-second clipboard change detection
- **Rich Content Support**: Text, images (PNG/JPEG), HTML, and RTF
- **Persistent History**: SQLite database with configurable retention
- **Search & Query**: CLI tools to search and browse clipboard history
- **Cross-Platform**: Works on macOS and Linux (X11/Wayland)
- **Flexible Architecture**: Run as server, client, or both
- **Network Protocol**: Efficient TCP-based protocol with optional authentication

## Architecture

```
┌─────────────────┐         TCP Socket         ┌─────────────────┐
│   macOS Host    │◄─────────────────────────►│   NixOS VM      │
│                 │                             │                 │
│  Clippy Daemon  │                             │  Clippy Daemon  │
│  (Server Mode)  │                             │  (Client Mode)  │
│                 │                             │                 │
│  ┌───────────┐  │                             │  ┌───────────┐  │
│  │ Clipboard │  │                             │  │ Clipboard │  │
│  │  Monitor  │  │                             │  │  Monitor  │  │
│  └───────────┘  │                             │  └───────────┘  │
│  ┌───────────┐  │                             │  ┌───────────┐  │
│  │  SQLite   │  │                             │  │  SQLite   │  │
│  │  History  │  │                             │  │  History  │  │
│  └───────────┘  │                             │  └───────────┘  │
└─────────────────┘                             └─────────────────┘
```

## Installation

### Using Nix Flakes (Recommended)

1. **Enter development environment:**
```bash
nix develop
```

2. **Build the project:**
```bash
cargo build --release
```

3. **Install (optional):**
```bash
cargo install --path .
```

### Manual Build

**Dependencies:**
- Rust nightly toolchain
- OpenSSL
- SQLite
- Platform-specific:
  - **macOS**: Xcode Command Line Tools
  - **Linux**: X11 or Wayland libraries

```bash
cargo build --release
```

## Configuration

### Initialize Configuration

```bash
clippy config --init
```

This creates `~/.config/clippy/config.toml` with default settings:

```toml
[server]
host = "0.0.0.0"
port = 9876
# auth_token = "optional-secret-token"

[client]
server_host = "127.0.0.1"  # Change to VM host IP for client
server_port = 9876
auto_connect = true
# auth_token = "optional-secret-token"

[storage]
max_history = 1000
max_content_size_mb = 10
# database_path = "/path/to/clipboard.db"  # Optional, auto-detected

[sync]
interval_ms = 500           # Clipboard check interval
retry_delay_ms = 5000       # Reconnection delay
heartbeat_interval_ms = 30000  # Keep-alive interval
```

### View Current Configuration

```bash
clippy config --show
```

## Usage

### Setup for Parallels VM + macOS

#### On macOS Host (Server)

1. **Initialize config:**
```bash
clippy config --init
```

2. **Start daemon in server mode:**
```bash
clippy start --server
```

Or run in both modes for bidirectional sync:
```bash
clippy start
```

#### On NixOS VM (Client)

1. **Initialize config:**
```bash
clippy config --init
```

2. **Edit config to point to host:**
```bash
# Edit ~/.config/clippy/config.toml
# Set client.server_host to your macOS IP address
# For Parallels, you can often use "10.211.55.2" or the host's network IP
```

3. **Start daemon in client mode:**
```bash
clippy start --client
```

Or run in both modes:
```bash
clippy start
```

### CLI Commands

#### Start Daemon

```bash
# Run as both server and client (bidirectional sync)
clippy start

# Run as server only (macOS host typically)
clippy start --server

# Run as client only (VM typically)
clippy start --client

# Enable verbose logging
clippy -v start
```

#### View Clipboard History

```bash
# Show last 20 entries
clippy history

# Show last 50 entries
clippy history --limit 50

# Show entries with offset (pagination)
clippy history --limit 20 --offset 40

# Filter by source
clippy history --source macos
clippy history --source nixos

# Filter by content type
clippy history --type-filter text
clippy history --type-filter image
```

#### Search History

```bash
# Search for text in clipboard history
clippy search "password"

# Limit results
clippy search "TODO" --limit 10
```

#### View Statistics

```bash
clippy stats
```

#### Clear History

```bash
# Interactive confirmation
clippy clear

# Skip confirmation
clippy clear --yes
```

## Network Setup

### Finding Your Host IP

**On macOS:**
```bash
# For Parallels VM, the host is typically accessible at:
# 10.211.55.2 (Shared Networking)
# Or use your macOS IP on the network:
ifconfig | grep "inet "
```

**On NixOS VM:**
```bash
# Test connectivity to host
ping 10.211.55.2

# Or find gateway (usually the host in Parallels)
ip route | grep default
```

### Firewall Configuration

**macOS:**
```bash
# Allow incoming connections on port 9876
# System Preferences → Security & Privacy → Firewall → Firewall Options
# Or use command line to allow the binary
```

**NixOS:**
Add to your configuration.nix:
```nix
networking.firewall.allowedTCPPorts = [ 9876 ];
```

## Running as a Service

### macOS (launchd)

Create `~/Library/LaunchAgents/com.clippy.daemon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clippy.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/clippy</string>
        <string>start</string>
        <string>--server</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/clippy.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/clippy.error.log</string>
</dict>
</plist>
```

Load the service:
```bash
launchctl load ~/Library/LaunchAgents/com.clippy.daemon.plist
```

### NixOS (systemd)

Add to your configuration.nix:

```nix
systemd.user.services.clippy = {
  description = "Clippy clipboard synchronization daemon";
  wantedBy = [ "default.target" ];
  serviceConfig = {
    ExecStart = "${pkgs.clippy}/bin/clippy start --client";
    Restart = "always";
    RestartSec = "5";
  };
};
```

Then rebuild and enable:
```bash
sudo nixos-rebuild switch
systemctl --user enable clippy
systemctl --user start clippy
```

## Troubleshooting

### Connection Issues

**Problem:** Client can't connect to server

**Solutions:**
1. Verify server is running: `ps aux | grep clippy`
2. Check firewall allows port 9876
3. Verify correct host IP in client config
4. Test connectivity: `telnet <host-ip> 9876`
5. Check logs with verbose mode: `clippy -v start`

### Clipboard Not Syncing

**Problem:** Clipboard changes aren't being detected

**Solutions:**
1. Check clipboard permissions (especially on macOS)
2. Verify daemon is running in correct mode
3. Check logs for errors
4. Reduce `interval_ms` in config for faster detection

### Performance Issues

**Problem:** High CPU or memory usage

**Solutions:**
1. Increase `interval_ms` to reduce polling frequency
2. Reduce `max_history` to limit database size
3. Set `max_content_size_mb` to prevent large items
4. Clear old history: `clippy clear --yes`

## Development

### Project Structure

```
clippy/
├── src/
│   ├── main.rs           # CLI entry point
│   ├── daemon.rs         # Background daemon
│   ├── server.rs         # TCP server
│   ├── client.rs         # TCP client
│   ├── clipboard/        # Clipboard access (macOS/Linux)
│   ├── storage/          # SQLite database layer
│   ├── sync/             # Network protocol
│   └── config.rs         # Configuration management
├── Cargo.toml
├── flake.nix            # Nix development environment
└── README.md
```

### Building

```bash
# Development build
cargo build

# Release build (optimized)
cargo build --release

# Run tests
cargo test

# Run with logging
RUST_LOG=debug cargo run -- start
```

### Contributing

Contributions are welcome! Areas for improvement:

- [ ] TLS encryption for network protocol
- [ ] Clipboard format preservation (RTF, etc.)
- [ ] File path synchronization
- [ ] Compression for large clipboard items
- [ ] Web UI for history browsing
- [ ] Multiple client support
- [ ] End-to-end encryption option

## License

MIT License - see LICENSE file for details

## Acknowledgments

Built with:
- [arboard](https://github.com/1Password/arboard) - Cross-platform clipboard access
- [tokio](https://tokio.rs/) - Async runtime
- [sqlx](https://github.com/launchbadge/sqlx) - Async SQLite
- [clap](https://github.com/clap-rs/clap) - CLI parsing
