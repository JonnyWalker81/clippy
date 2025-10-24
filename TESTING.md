# Testing Clippy with Comprehensive Logging

## What Was Fixed

**Bug Found:** The server was receiving clipboard updates but **not applying them to the local clipboard**.

**Fix:** Added `apply_clipboard_update()` to the server so it now:
1. Receives clipboard update from client
2. Stores in database ✓
3. **Applies to local macOS clipboard** ✓ (NEW!)

## Comprehensive Logging

The application now logs every step of the clipboard sync process with emojis for easy tracking:

### Clipboard Detection (on the copying side)
```
🔍 Detected LOCAL clipboard change (type: text, checksum: abc12345)
📋 Content preview: Hello from NixOS!
📤 Sending clipboard update to server...
✓ Clipboard update sent to server
```

### Network Transfer (client → server)
```
📤 Sending clipboard update to server (type: text, source: nixos, checksum: abc12345)
```

### Server Reception (on macOS)
```
Received clipboard update from nixos (type: text, size: 18 bytes, checksum: abc12345)
Stored clipboard entry in database
✓ Applied clipboard update to local clipboard
```

### Acknowledgment (server → client)
```
✓ Server acknowledged clipboard sync: abc12345
```

### Clipboard Application (on the receiving side)
```
📥 Received clipboard update from nixos (type: text, checksum: abc12345, size: 18 bytes)
📋 Applying clipboard update to local clipboard...
✓ Successfully applied clipboard update
```

## Step-by-Step Testing

### Setup: Rebuild and Deploy

**On macOS Host:**
```bash
cd ~/Repositories/clippy
cargo build --release
cp target/release/clippy /usr/local/bin/  # Optional: for easy access
```

**On NixOS VM:**
```bash
cd ~/Repositories/clippy
cargo build --release
```

### Test 1: NixOS → macOS (The original issue)

**Terminal 1 (macOS Host):**
```bash
# Start server with verbose logging
clippy -v start --server
```

Expected initial output:
```
INFO Starting in server-only mode
INFO Clipboard server listening on 0.0.0.0:9876
```

**Terminal 2 (NixOS VM):**
```bash
# Start client with verbose logging
clippy -v start --client
```

Expected initial output:
```
INFO Connecting to server at 10.211.55.1:9876...
INFO Connected to server
INFO Authentication successful
INFO Starting clipboard monitor (checking every 500ms)
```

**Test Action on NixOS VM:**
```bash
# Copy some text
echo "Hello from NixOS!" | xclip -selection clipboard
# or use your text editor/terminal to copy
```

**Expected logs on NixOS (within 500ms):**
```
🔍 Detected LOCAL clipboard change (type: text, checksum: abc12345)
📋 Content preview: Hello from NixOS!
📤 Sending clipboard update to server...
✓ Clipboard update sent to server
📤 Sending clipboard update to server (type: text, source: nixos, checksum: abc12345)
✓ Server acknowledged clipboard sync: abc12345
```

**Expected logs on macOS:**
```
INFO New connection from: 10.211.55.X:XXXXX
INFO Received clipboard update from nixos (type: text, size: 18 bytes, checksum: abc12345)
INFO Stored clipboard entry in database
INFO ✓ Applied clipboard update to local clipboard
```

**Verification on macOS:**
```bash
# Paste (Cmd+V) in any application
# Should show: "Hello from NixOS!"

# Or check programmatically:
pbpaste
```

✅ **SUCCESS**: You should see "Hello from NixOS!" on macOS!

### Test 2: macOS → NixOS (Reverse direction)

**Test Action on macOS:**
```bash
# Copy some text
echo "Hello from macOS!" | pbcopy
```

**Expected logs on macOS:**
```
🔍 Detected LOCAL clipboard change (type: text, checksum: def67890)
📋 Content preview: Hello from macOS!
📤 Sending clipboard update to server...
✓ Clipboard update sent to server
```

Wait... this won't work in client-only mode! You need to run in proper mode.

### Correct Setup for Bidirectional Sync

For true bidirectional sync, you need:
- **macOS**: Run as **server only** OR **both modes**
- **NixOS**: Run as **client only** OR **both modes**

#### Option A: Server (macOS) + Client (NixOS)
```bash
# macOS: Server only
clippy -v start --server

# NixOS: Client only
clippy -v start --client
```
**Note**: This only syncs **NixOS → macOS**, not the reverse!

#### Option B: Both Modes (Bidirectional)

**macOS (runs both server + client):**
```bash
# Edit config first:
nano ~/.config/clippy/config.toml
# Set: client.server_host = "127.0.0.1"  # Connect to itself

# Start both modes
clippy -v start
```

**NixOS (runs both server + client):**
```bash
# Edit config first:
nano ~/.config/clippy/config.toml
# Set: client.server_host = "10.211.55.1"  # macOS IP

# Start both modes
clippy -v start
```

Now:
- Copy on NixOS → Detected by NixOS → Sent to macOS → Applied on macOS
- Copy on macOS → Detected by macOS → Sent to self & NixOS → Applied everywhere

### Test 3: Image Sync

**Copy an image on NixOS:**
```bash
# Take a screenshot or copy an image
```

**Expected logs:**
```
🔍 Detected LOCAL clipboard change (type: image, checksum: xyz98765)
📋 Content preview: [Image: 123456 bytes]
📤 Sending clipboard update to server...
```

**On macOS:**
```
INFO Received clipboard update from nixos (type: image, size: 123456 bytes, checksum: xyz98765)
INFO Stored clipboard entry in database
INFO ✓ Applied clipboard update to local clipboard
```

**Verification:** Paste (Cmd+V) in Preview, Photoshop, etc. - image should appear!

## Troubleshooting with Logs

### Issue: No "Detected LOCAL clipboard change" logs

**Problem:** Clipboard monitoring not working

**Check:**
1. Is clipboard polling working?
   - Look for "Starting clipboard monitor" message
   - Check `interval_ms` in config (should be 500ms)

2. Clipboard permissions?
   - macOS: System Preferences → Security → Privacy → Accessibility
   - Linux: Check if xclip/wl-clipboard works

3. Try manual test:
   ```bash
   # Copy something and wait 1 second
   echo "test" | xclip -selection clipboard
   sleep 1
   # Should see logs within 500ms
   ```

### Issue: Logs show "Sending to server" but no "Received" on server

**Problem:** Network issue or server not receiving

**Check:**
1. Connection logs on client:
   - Should see "Connected to server"
   - If seeing reconnection attempts, connection is broken

2. Server logs for new connections:
   - Should see "New connection from: ..."
   - If not, firewall or network issue

3. Test raw connectivity:
   ```bash
   nc -zv <macos-ip> 9876
   ```

### Issue: Server logs "Received" but no "Applied"

**Problem:** Error applying to clipboard

**Check:**
1. Look for error logs:
   - "Failed to apply clipboard update locally: ..."

2. Content type supported?
   - Currently: text, image, html
   - May need to add more types

3. Clipboard access permissions?
   - macOS needs proper entitlements/permissions

### Issue: Applied but can't paste

**Problem:** Clipboard format issue

**Check:**
1. What content type?
   ```
   type: text   - Should work in all apps
   type: image  - Should work in image apps
   type: html   - May not work everywhere
   ```

2. Size limit?
   - Check `max_content_size_mb` in config
   - Very large items may be rejected

## Performance Monitoring

### Check Polling Frequency
```bash
# Count how many times clipboard is checked per minute
clippy -v start --client 2>&1 | grep "Detected LOCAL" | wc -l
# Should be 0 if no changes, or show count of actual changes
```

### Check Latency
Use the timestamps in logs to measure sync time:
```
NixOS: 20:10:30.123 🔍 Detected LOCAL clipboard change
macOS: 20:10:30.456 INFO Received clipboard update
```
Latency = 456 - 123 = 333ms (excellent!)

### Adjust Polling Interval
If CPU usage is high:
```toml
# ~/.config/clippy/config.toml
[sync]
interval_ms = 1000  # Check every 1 second instead of 500ms
```

## Logging Levels

### Minimal Logging (Production)
```bash
clippy start --server  # No -v flag
```
Shows only important events (errors, connections)

### Verbose Logging (Development/Debug)
```bash
clippy -v start --server  # With -v flag
```
Shows all clipboard changes, sends, receives

### Debug Logging (Ultra Verbose)
```bash
RUST_LOG=debug clippy -v start --server
```
Shows internal state, network details, everything

## Common Log Patterns

### ✅ Successful Sync (NixOS → macOS)
```
NixOS:
  🔍 Detected LOCAL clipboard change
  📤 Sending clipboard update to server
  ✓ Clipboard update sent to server
  ✓ Server acknowledged clipboard sync

macOS:
  INFO Received clipboard update from nixos
  INFO Stored clipboard entry in database
  INFO ✓ Applied clipboard update to local clipboard
```

### ❌ Network Disconnection
```
Client:
  ERROR Connection refused (os error 111)
  INFO Reconnecting in 5000 ms...

Server:
  Connection closed
```

### ❌ Clipboard Access Error
```
Server:
  INFO Received clipboard update from nixos
  ERROR Failed to apply clipboard update locally: ...
```

### ❌ Authentication Failure
```
Client:
  ERROR Authentication failed: Invalid token
```

## Quick Reference Commands

```bash
# Start with logging
clippy -v start --server    # macOS
clippy -v start --client    # NixOS

# View history (see what was synced)
clippy history --limit 10

# Check stats
clippy stats

# Test manual copy
echo "test" | pbcopy          # macOS
echo "test" | xclip -sel c    # Linux

# Check what's in clipboard
pbpaste                       # macOS
xclip -o -sel c              # Linux
```

## Next Steps

Once clipboard sync is confirmed working:
1. Remove `-v` flag for cleaner logs in production
2. Set up as system service (launchd/systemd)
3. Configure auto-start on boot
4. Enjoy seamless clipboard sync! 🎉
