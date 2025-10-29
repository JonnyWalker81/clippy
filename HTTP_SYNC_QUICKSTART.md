# HTTP-Based Clipboard Sync - Quick Start Guide

This guide will help you set up the new HTTP-based clipboard synchronization system between macOS and NixOS.

## Architecture Overview

The new system uses an HTTP server architecture:
- **Rust HTTP Server** (runs on macOS): REST API for clipboard storage with history
- **Clients** (choose one option):
  - **Option 1: Bash Scripts** (lightweight, no compilation needed)
    - macOS Client: Uses pbcopy/pbpaste
    - NixOS Client: Uses xclip/xsel/wl-clipboard
  - **Option 2: Rust CLI** (unified, cross-platform)
    - Single binary works on both macOS and NixOS
    - Uses native clipboard APIs via `arboard` library

### Advantages
- ✅ Standard HTTP protocol (easy to debug with curl, browsers)
- ✅ Clipboard history (up to 100 items)
- ✅ Stateless design (simpler than bidirectional TCP)
- ✅ Multi-client ready (can sync multiple VMs)
- ✅ Foundation for future web UI

## Quick Start

### 1. Build the HTTP Server

```bash
# Build the server
cargo build --bin clipboard_server --release

# Or run directly in debug mode
cargo run --bin clipboard_server
```

### 2. Start the Server (macOS Host)

```bash
# Run in foreground (recommended for testing)
cargo run --bin clipboard_server

# Or run in background
cargo run --bin clipboard_server &

# Server will start on http://0.0.0.0:8080
```

### 3. Start Clients

#### Option A: Bash Scripts (Recommended for Quick Start)

```bash
# macOS Client
./scripts/native-sync-macos.sh start

# NixOS Client (in VM)
./scripts/native-sync-nixos.sh start
```

#### Option B: Rust CLI (Unified Cross-Platform Client)

```bash
# Build the Rust CLI (one-time, both platforms)
cargo build --bin clippy --release

# On macOS
./target/release/clippy sync -s http://localhost:8080 -i 200

# On NixOS (in VM)
./target/release/clippy sync -s http://10.211.55.2:8080 -i 200

# Or use defaults from config (server and interval)
./target/release/clippy sync
```

### 5. Test the Sync

```bash
# Run health check
./scripts/native-sync-check.sh check

# Or quick check
./scripts/native-sync-check.sh quick

# Or test sync
./scripts/native-sync-check.sh test
```

## API Endpoints

The HTTP server exposes the following endpoints:

### Health Check
```bash
curl http://localhost:8080/health
```

Response:
```json
{
  "status": "healthy",
  "items_count": 5,
  "uptime_seconds": 123
}
```

### Submit Clipboard
```bash
curl -X POST http://localhost:8080/api/clipboard \
  -H "Content-Type: application/json" \
  -d '{"content": "SGVsbG8gV29ybGQ="}'
```

Response:
```json
{
  "id": 1,
  "hash": "abc123...",
  "timestamp": "2025-10-28T..."
}
```

### Get Latest Clipboard
```bash
curl http://localhost:8080/api/clipboard/latest
```

Response:
```json
{
  "id": 1,
  "content": "SGVsbG8gV29ybGQ=",
  "hash": "abc123...",
  "timestamp": "2025-10-28T...",
  "size": 11
}
```

### Get Clipboard History
```bash
curl http://localhost:8080/api/clipboard/history
```

Response:
```json
{
  "items": [
    {
      "id": 1,
      "content": "SGVsbG8gV29ybGQ=",
      "hash": "abc123...",
      "timestamp": "2025-10-28T...",
      "size": 11
    }
  ],
  "total": 1
}
```

## Configuration

### Server Configuration

Environment variables for the HTTP server:

```bash
export CLIPBOARD_SERVER_HOST=0.0.0.0      # Bind address
export CLIPBOARD_SERVER_PORT=8080         # HTTP port
```

### Client Configuration

#### macOS Client

```bash
export CLIPBOARD_SERVER_URL=http://localhost:8080
export CLIPBOARD_POLL_INTERVAL=0.2        # 200ms polling
export CLIPBOARD_VERBOSE=1                # Enable verbose logging
export CLIPBOARD_LOG=/tmp/native-sync-macos.log
```

#### NixOS Client

```bash
export CLIPBOARD_SERVER_URL=http://10.211.55.2:8080
export CLIPBOARD_POLL_INTERVAL=0.2
export CLIPBOARD_VERBOSE=1
export CLIPBOARD_LOG=/tmp/native-sync-nixos.log
```

## Stopping Services

```bash
# Stop server (if running in background)
pkill -f clipboard_server

# Stop macOS client
./scripts/native-sync-macos.sh stop

# Stop NixOS client
./scripts/native-sync-nixos.sh stop
```

## Troubleshooting

### Check Server Status

```bash
# Full diagnostics
./scripts/native-sync-check.sh check

# Server only
./scripts/native-sync-check.sh server

# Quick status
./scripts/native-sync-check.sh quick
```

### View Logs

```bash
# macOS client logs
tail -f /tmp/native-sync-macos.log

# NixOS client logs
tail -f /tmp/native-sync-nixos.log

# Server logs (if running with RUST_LOG)
RUST_LOG=info cargo run --bin clipboard_server
```

### Test Manual Sync

```bash
# On macOS - copy text
echo "test from macos" | pbcopy

# Check server received it
curl http://localhost:8080/api/clipboard/latest | jq -r '.content' | base64 -D

# On NixOS - copy text
echo "test from nixos" | xclip -selection clipboard

# Check server received it
curl http://10.211.55.2:8080/api/clipboard/latest | jq -r '.content' | base64 -d
```

### Common Issues

#### Server not accessible from VM

1. Check firewall on macOS:
   ```bash
   # System Preferences → Security & Privacy → Firewall
   # Allow incoming connections for clipboard_server
   ```

2. Verify network connectivity:
   ```bash
   # From NixOS VM
   ping 10.211.55.2
   curl http://10.211.55.2:8080/health
   ```

3. Check server is binding to 0.0.0.0:
   ```bash
   lsof -i :8080
   netstat -an | grep 8080
   ```

#### Clipboard not syncing

1. Check both clients are running:
   ```bash
   ./scripts/native-sync-check.sh quick
   ```

2. Check logs for errors:
   ```bash
   tail -20 /tmp/native-sync-macos.log
   tail -20 /tmp/native-sync-nixos.log
   ```

3. Verify server has items:
   ```bash
   curl http://localhost:8080/api/clipboard/history
   ```

## Performance Notes

- **Polling interval**: Default 200ms (configurable)
- **History size**: Max 100 items (FIFO)
- **Max clipboard size**: 10MB per item
- **Echo prevention**: Hash-based deduplication prevents sync loops

## Future Enhancements

- [ ] Web UI for viewing clipboard history
- [ ] Authentication/API keys
- [ ] WebSocket support for push notifications (instead of polling)
- [ ] Persistent storage (SQLite)
- [ ] Multiple clipboard formats (text, images, files)
- [ ] Clipboard item search and filtering

## Comparison with TCP Version

| Feature | TCP Version | HTTP Version |
|---------|-------------|--------------|
| Protocol | Custom TCP | Standard HTTP/JSON |
| Server | macOS (socat) | Rust HTTP server |
| Debugging | socat logs | curl, browser, HTTP tools |
| History | No | Yes (100 items) |
| Multi-client | Single client | Multiple clients |
| Web UI | No | Easy to add |
| Complexity | Medium | Low |

## Testing Checklist

- [ ] Server starts and responds to /health
- [ ] macOS client starts and connects
- [ ] NixOS client starts and connects
- [ ] Copy on macOS → appears on NixOS
- [ ] Copy on NixOS → appears on macOS
- [ ] No echo loops (clipboard doesn't keep updating itself)
- [ ] History accumulates properly
- [ ] Clients reconnect after server restart

## Example Session

```bash
# Terminal 1: Start server
$ cargo run --bin clipboard_server
🚀 Clipboard HTTP Server starting
📍 Listening on http://0.0.0.0:8080
...

# Terminal 2: Start macOS client
$ ./scripts/native-sync-macos.sh start
[2025-10-28 ...] 🚀 Starting native clipboard sync (HTTP client)
[2025-10-28 ...] ✓ Using macOS clipboard (pbcopy/pbpaste)
[2025-10-28 ...] ✅ Server is reachable
[2025-10-28 ...] 🔍 Starting local clipboard monitor
[2025-10-28 ...] 📥 Starting server poll loop

# Terminal 3: Test
$ echo "Hello from macOS" | pbcopy
# Wait a moment, then in NixOS VM:
$ xclip -o -selection clipboard
Hello from macOS

# Check history
$ curl http://localhost:8080/api/clipboard/history | jq
```

## Support

For issues or questions:
1. Check logs: `/tmp/native-sync-*.log`
2. Run diagnostics: `./scripts/native-sync-check.sh check`
3. Test API manually with curl
4. Check GitHub issues
