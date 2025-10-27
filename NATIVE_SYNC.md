# Native Clipboard Sync

Lightweight bash scripts for bidirectional clipboard synchronization between NixOS VM and macOS host using native clipboard tools.

## Overview

This is a simpler alternative to the full Rust daemon, using only native clipboard utilities and bash scripts:
- **macOS**: Uses `pbcopy` and `pbpaste` (built-in)
- **NixOS/Linux**: Uses `xclip`, `xsel`, or `wl-clipboard` (auto-detected)
- **Communication**: TCP sockets on port 9877
- **Sync**: Bidirectional with 200ms polling
- **Protocol**: Simple text-based (CLIP:base64, PING/PONG)

## Quick Start

### On macOS Host (Server)

1. **Install socat (recommended for better performance)**
   ```bash
   brew install socat
   ```

2. **Start the server**
   ```bash
   cd /path/to/clippy
   ./scripts/native-sync-macos.sh start
   ```

3. **Check status**
   ```bash
   ./scripts/native-sync-check.sh
   ```

### On NixOS VM (Client)

1. **Install required tools**
   ```bash
   # For X11
   nix-shell -p xclip socat netcat

   # For Wayland
   nix-shell -p wl-clipboard socat netcat
   ```

2. **Set macOS host IP** (if not using default)
   ```bash
   export NATIVE_SYNC_HOST="10.211.55.2"  # Adjust to your macOS IP
   ```

3. **Start the client**
   ```bash
   cd /path/to/clippy
   ./scripts/native-sync-nixos.sh start
   ```

4. **Check status**
   ```bash
   ./scripts/native-sync-check.sh
   ```

### Test the Sync

On either machine, run:
```bash
./scripts/native-sync-check.sh test
```

This will copy a test string to the clipboard. Check the other machine to verify it synced!

## Architecture

```
┌──────────────────────────────────────┐
│         macOS Host (Server)          │
│                                      │
│  ┌────────────────────────────────┐ │
│  │  native-sync-macos.sh          │ │
│  │                                 │ │
│  │  • pbpaste (monitor)            │ │
│  │  • TCP Server :9877             │ │
│  │  • pbcopy (apply)               │ │
│  └────────────────────────────────┘ │
│              ↕                       │
│         Port 9877                    │
└──────────────────────────────────────┘
              ↕
         TCP Socket
              ↕
┌──────────────────────────────────────┐
│        NixOS VM (Client)             │
│                                      │
│  ┌────────────────────────────────┐ │
│  │  native-sync-nixos.sh          │ │
│  │                                 │ │
│  │  • xclip/xsel/wl-paste (mon)   │ │
│  │  • TCP Client → :9877           │ │
│  │  • xclip/xsel/wl-copy (apply)  │ │
│  └────────────────────────────────┘ │
└──────────────────────────────────────┘
```

## Protocol

Simple line-based text protocol over TCP:

- `CLIP:<base64>` - Clipboard update with base64-encoded content
- `ACK:<hash>` - Server acknowledges update with content hash
- `NAK` - Server rejects update
- `PING` - Heartbeat request
- `PONG` - Heartbeat response

Example:
```
Client → Server: CLIP:SGVsbG8gV29ybGQh
Server → Client: ACK:5eb63bbb
```

## Scripts

### native-sync-macos.sh

macOS server script that:
- Listens on TCP port 9877
- Monitors local clipboard every 200ms
- Sends clipboard changes to connected clients
- Receives clipboard updates from clients and applies them
- Provides health check and logging

**Usage:**
```bash
./scripts/native-sync-macos.sh start        # Start server
./scripts/native-sync-macos.sh stop         # Stop server
./scripts/native-sync-macos.sh check        # Health check
```

**Environment Variables:**
- `NATIVE_SYNC_PORT` - TCP port (default: 9877)
- `NATIVE_SYNC_INTERVAL` - Poll interval in seconds (default: 0.2)
- `NATIVE_SYNC_VERBOSE` - Enable verbose output (default: 1)
- `NATIVE_SYNC_LOG` - Log file path (default: /tmp/native-sync-macos.log)

### native-sync-nixos.sh

NixOS/Linux client script that:
- Connects to macOS server
- Auto-detects clipboard tool (xclip/xsel/wl-clipboard)
- Monitors local clipboard every 200ms
- Sends clipboard changes to server
- Receives clipboard updates from server and applies them
- Auto-reconnects on disconnection

**Usage:**
```bash
./scripts/native-sync-nixos.sh start        # Start client
./scripts/native-sync-nixos.sh stop         # Stop client
./scripts/native-sync-nixos.sh check        # Health check
./scripts/native-sync-nixos.sh ping         # Ping server
```

**Environment Variables:**
- `NATIVE_SYNC_HOST` - Server hostname/IP (default: 10.211.55.2)
- `NATIVE_SYNC_PORT` - Server port (default: 9877)
- `NATIVE_SYNC_INTERVAL` - Poll interval in seconds (default: 0.2)
- `NATIVE_SYNC_VERBOSE` - Enable verbose output (default: 1)
- `NATIVE_SYNC_LOG` - Log file path (default: /tmp/native-sync-nixos.log)

### native-sync-check.sh

Health check and diagnostic tool:
- Shows process status
- Verifies network connectivity
- Checks clipboard tool availability
- Displays recent log entries
- Tests clipboard sync

**Usage:**
```bash
./scripts/native-sync-check.sh              # Full status check
./scripts/native-sync-check.sh quick        # Quick check
./scripts/native-sync-check.sh test         # Test clipboard sync
```

## Installation as Service

### macOS (launchd)

1. **Edit the plist file**
   ```bash
   nano scripts/native-sync-macos.plist
   ```

   Change `YOUR_USERNAME` and `/path/to/clippy` to actual values.

2. **Copy to LaunchAgents**
   ```bash
   cp scripts/native-sync-macos.plist ~/Library/LaunchAgents/com.clippy.native-sync.plist
   ```

3. **Load the service**
   ```bash
   launchctl load ~/Library/LaunchAgents/com.clippy.native-sync.plist
   ```

4. **Start the service**
   ```bash
   launchctl start com.clippy.native-sync
   ```

5. **Check status**
   ```bash
   launchctl list | grep native-sync
   ```

**To stop:**
```bash
launchctl stop com.clippy.native-sync
launchctl unload ~/Library/LaunchAgents/com.clippy.native-sync.plist
```

**View logs:**
```bash
tail -f /tmp/native-sync-macos-stdout.log
tail -f /tmp/native-sync-macos-stderr.log
tail -f /tmp/native-sync-macos.log
```

### NixOS (systemd)

#### Option 1: Using systemd user service (manual)

1. **Edit the service file**
   ```bash
   nano scripts/native-sync-nixos.service
   ```

   Change `YOUR_USERNAME` and `/path/to/clippy` to actual values.

2. **Copy to systemd user directory**
   ```bash
   mkdir -p ~/.config/systemd/user
   cp scripts/native-sync-nixos.service ~/.config/systemd/user/
   ```

3. **Reload systemd**
   ```bash
   systemctl --user daemon-reload
   ```

4. **Enable and start**
   ```bash
   systemctl --user enable native-sync-nixos
   systemctl --user start native-sync-nixos
   ```

5. **Check status**
   ```bash
   systemctl --user status native-sync-nixos
   ```

**View logs:**
```bash
journalctl --user -u native-sync-nixos -f
tail -f /tmp/native-sync-nixos.log
```

#### Option 2: Using NixOS configuration.nix (recommended)

Add to your `configuration.nix`:

```nix
{
  # Install required packages
  environment.systemPackages = with pkgs; [
    xclip      # or wl-clipboard for Wayland
    socat
    netcat
  ];

  # Create systemd user service
  systemd.user.services.native-sync = {
    description = "Native Clipboard Sync Client";
    after = [ "graphical-session.target" "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "graphical-session.target" ];

    serviceConfig = {
      Type = "simple";
      # CHANGE THIS PATH
      ExecStart = "/home/YOUR_USERNAME/path/to/clippy/scripts/native-sync-nixos.sh start";
      Restart = "on-failure";
      RestartSec = "5s";
      Environment = [
        "NATIVE_SYNC_HOST=10.211.55.2"
        "NATIVE_SYNC_PORT=9877"
        "NATIVE_SYNC_INTERVAL=0.2"
        "NATIVE_SYNC_VERBOSE=1"
        "DISPLAY=:0"
      ];
    };
  };
}
```

Then rebuild:
```bash
sudo nixos-rebuild switch
systemctl --user start native-sync
```

## Configuration

### Finding Your macOS Host IP

On macOS:
```bash
ifconfig | grep "inet " | grep -v 127.0.0.1
```

For Parallels VMs, the host is typically at `10.211.55.2` (Shared Networking).

### Firewall Configuration

**macOS:**
- System Preferences → Security & Privacy → Firewall
- Click "Firewall Options"
- Allow incoming connections for your terminal or the script
- Or disable firewall temporarily for testing

**NixOS:**
The client doesn't need open ports (only outgoing connections).

### Changing the Port

If port 9877 conflicts with something else:

**On macOS:**
```bash
export NATIVE_SYNC_PORT=9999
./scripts/native-sync-macos.sh start
```

**On NixOS:**
```bash
export NATIVE_SYNC_PORT=9999
./scripts/native-sync-nixos.sh start
```

Update service files accordingly if using services.

### Adjusting Sync Speed

For faster sync (more CPU usage):
```bash
export NATIVE_SYNC_INTERVAL=0.1  # 100ms
```

For slower sync (less CPU usage):
```bash
export NATIVE_SYNC_INTERVAL=0.5  # 500ms
```

## Troubleshooting

### "Cannot connect to server"

**Check server is running:**
```bash
# On macOS
ps aux | grep native-sync-macos
lsof -i :9877
```

**Check network connectivity:**
```bash
# On NixOS
ping 10.211.55.2
nc -zv 10.211.55.2 9877
```

**Check firewall:**
- Make sure macOS firewall allows the connection
- Try temporarily disabling firewall for testing

### "Clipboard tool not found"

**On NixOS (X11):**
```bash
nix-shell -p xclip
# or add to configuration.nix
```

**On NixOS (Wayland):**
```bash
nix-shell -p wl-clipboard
# or add to configuration.nix
```

### "Clipboard is empty"

This is usually an issue with clipboard managers on Linux.

**Check if you can read clipboard manually:**
```bash
# X11
xclip -o -selection clipboard

# Wayland
wl-paste
```

**Solution:** Install a clipboard manager
```nix
# In configuration.nix
services.clipmenu.enable = true;
# or
services.greenclip.enable = true;
```

### Clipboard sync is slow

**Decrease poll interval:**
```bash
export NATIVE_SYNC_INTERVAL=0.1  # Poll every 100ms
```

**Use socat instead of nc:**
```bash
# macOS
brew install socat

# NixOS
nix-shell -p socat
```

### High CPU usage

**Increase poll interval:**
```bash
export NATIVE_SYNC_INTERVAL=0.5  # Poll every 500ms
```

**Check for errors in logs:**
```bash
tail -f /tmp/native-sync-*.log
```

### Clipboard sync loops

If you see the same content being synced repeatedly:
- This means the checksum isn't working correctly
- Check if clipboard content is stable (some apps modify content)
- Check logs to see if content is actually different

### Service won't start on boot

**macOS:**
```bash
# Check for errors
launchctl list | grep native-sync
cat /tmp/native-sync-macos-stderr.log
```

**NixOS:**
```bash
# Check service status
systemctl --user status native-sync-nixos

# Check logs
journalctl --user -u native-sync-nixos -b
```

Common issues:
- Wrong paths in service files
- Missing DISPLAY environment variable
- Service starts before display server is ready

### View Detailed Logs

**macOS:**
```bash
tail -f /tmp/native-sync-macos.log
```

**NixOS:**
```bash
tail -f /tmp/native-sync-nixos.log
# or
journalctl --user -u native-sync-nixos -f
```

## Comparison with Rust Daemon

| Feature | Native Sync (Bash) | Rust Daemon |
|---------|-------------------|-------------|
| **Setup** | Simple bash scripts | Requires Rust compilation |
| **Dependencies** | pbcopy, xclip, socat | Rust, cargo, build tools |
| **Performance** | Good (200ms latency) | Excellent (<50ms latency) |
| **CPU Usage** | Low (bash + polling) | Very low (async I/O) |
| **Memory** | ~5 MB | ~10 MB |
| **Features** | Basic sync | History, search, multiple clients |
| **Protocol** | Simple text | Binary protocol |
| **Security** | None | Optional auth token |
| **Logging** | File-based | Structured logging |
| **Reliability** | Good | Excellent |
| **Debugging** | Easy (readable logs) | Moderate |

**Use Native Sync when:**
- You want quick setup without compilation
- You prefer simple bash scripts
- You don't need clipboard history
- You want easy customization

**Use Rust Daemon when:**
- You need maximum performance
- You want clipboard history
- You need multiple clients
- You want authentication

## Advanced Usage

### Running Both Server and Client on Same Machine

For testing locally on NixOS only:

```bash
# Terminal 1: Start server
NATIVE_SYNC_HOST=127.0.0.1 ./scripts/native-sync-macos.sh start

# Terminal 2: Start client
NATIVE_SYNC_HOST=127.0.0.1 ./scripts/native-sync-nixos.sh start
```

### Custom Port and Host

```bash
# Server
NATIVE_SYNC_PORT=8888 ./scripts/native-sync-macos.sh start

# Client
NATIVE_SYNC_HOST=192.168.1.100 NATIVE_SYNC_PORT=8888 ./scripts/native-sync-nixos.sh start
```

### Quiet Mode (No Console Output)

```bash
NATIVE_SYNC_VERBOSE=0 ./scripts/native-sync-macos.sh start
```

### Multiple Clients

The server supports multiple clients simultaneously. Just connect multiple NixOS VMs to the same server:

```bash
# VM 1
./scripts/native-sync-nixos.sh start

# VM 2
./scripts/native-sync-nixos.sh start

# All VMs will sync with each other via the server
```

### Integration with Other Tools

**Use with tmux clipboard:**
```bash
# Add to ~/.tmux.conf
bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "xclip -selection clipboard"
```

**Use with vim:**
```vim
" In ~/.vimrc
set clipboard=unnamedplus
```

## Security Considerations

⚠️ **WARNING:** This implementation has NO ENCRYPTION or AUTHENTICATION.

- All clipboard content is sent in plaintext (base64) over TCP
- Anyone who can connect to port 9877 can read/write your clipboard
- Only use on trusted networks (VM ↔ Host)

**For secure clipboard sync:**
- Use the full Rust daemon with authentication
- Or tunnel through SSH: `ssh -L 9877:localhost:9877 user@host`
- Or use VPN between machines

## Contributing

Improvements welcome! Areas for enhancement:
- [ ] Encryption support (TLS/SSL)
- [ ] Authentication tokens
- [ ] Image/binary clipboard support
- [ ] Clipboard history
- [ ] Conflict resolution strategies
- [ ] Performance optimizations

## License

MIT License - see LICENSE file for details

## See Also

- [README.md](README.md) - Main Clippy documentation
- [QUICKSTART.md](QUICKSTART.md) - Quick start guide for Rust daemon
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Detailed troubleshooting
