# Test Bidirectional Clipboard Sync

## 🐛 Issue Fixed

**Problem:** NixOS client was logging "📤 Sent to server" but macOS server never received the data. The clipboard changes from NixOS were not being applied to macOS.

**Root Cause:** The socat pipe was one-way. The background process was writing to stdout, but that stdout wasn't connected back to socat/server.

**Fix:** Changed to use `socat EXEC` mode which provides proper bidirectional stdin/stdout connection.

## 📦 What to Do

### 1. Pull Latest Code

**On both NixOS VM and macOS host:**
```bash
cd /path/to/clippy
git pull
```

You should see commit `9125b06` - "Fix NixOS → macOS clipboard sync"

### 2. Stop Old Processes

**On NixOS VM:**
```bash
./scripts/native-sync-nixos.sh stop
pkill -f native-sync-nixos  # Kill any stragglers
```

**On macOS Host:**
```bash
./scripts/native-sync-macos.sh stop
pkill -f native-sync-macos  # Kill any stragglers
```

### 3. Verify socat is Installed

**On macOS:**
```bash
which socat
# If not found:
brew install socat
```

**On NixOS:**
```bash
which socat
# If not found:
nix-shell -p socat
```

### 4. Start Server (macOS)

```bash
cd /path/to/clippy
./scripts/native-sync-macos.sh start
```

Expected output:
```
[2025-10-26 XX:XX:XX.XXX] 🚀 Starting native clipboard sync server on port 9877
[2025-10-26 XX:XX:XX.XXX] 📍 Log file: /tmp/native-sync-macos.log
[2025-10-26 XX:XX:XX.XXX] 📂 State directory: /tmp/native-sync-server
[2025-10-26 XX:XX:XX.XXX] ✓ Starting socat TCP server
```

### 5. Start Client (NixOS)

```bash
cd /path/to/clippy
./scripts/native-sync-nixos.sh start
```

Expected output:
```
[2025-10-26 XX:XX:XX.XXX] ✓ Using Wayland clipboard (wl-clipboard)
[2025-10-26 XX:XX:XX.XXX] 🔗 Connecting to server at 10.211.55.2:9877
[2025-10-26 XX:XX:XX.XXX] 📞 Establishing connection...
[2025-10-26 XX:XX:XX.XXX] ✅ Connected to server
```

## 🧪 Test Cases

Open two terminal windows side by side (or tmux/screen):
- **Terminal 1 (NixOS):** `tail -f /tmp/native-sync-nixos.log`
- **Terminal 2 (macOS):** `tail -f /tmp/native-sync-macos.log`

### Test 1: NixOS → macOS (THE FIX!)

**On NixOS VM:**
```bash
echo "Test from NixOS at $(date)" | wl-copy
```

**Expected in NixOS log (Terminal 1):**
```
[...] 🔍 Local clipboard changed: 'Test from NixOS at ...' (XX bytes, hash: XXXXXXXX)
[...] 📤 Sent to server (stdout)
```

**Expected in macOS log (Terminal 2):**
```
[...] 📥 Received from client: 'Test from NixOS at ...' (XX bytes, hash: XXXXXXXX)
[...] ✅ Applied to local clipboard
```

**Verify on macOS:**
```bash
pbpaste
# Should show: Test from NixOS at ...
```

✅ **If you see the text on macOS, NixOS → macOS sync works!**

### Test 2: macOS → NixOS (Was Already Working)

**On macOS Host:**
```bash
echo "Test from macOS at $(date)" | pbcopy
```

**Expected in macOS log (Terminal 2):**
```
[...] 🔍 Local clipboard changed: 'Test from macOS at ...' (XX bytes, hash: XXXXXXXX)
[...] 📤 Sent to client
```

**Expected in NixOS log (Terminal 1):**
```
[...] 📥 Received from server: 'Test from macOS at ...' (XX bytes, hash: XXXXXXXX)
[...] ✅ Applied to local clipboard
```

**Verify on NixOS:**
```bash
wl-paste
# Should show: Test from macOS at ...
```

✅ **If you see the text on NixOS, macOS → NixOS sync works!**

### Test 3: Loop Prevention

Copy text on NixOS, wait for it to appear on macOS. The logs should NOT show it being synced back to NixOS (because it's the same content).

**Expected in NixOS log:**
```
[...] ⏭️  Skipping (already synced, hash: XXXXXXXX)
```

✅ **If you see "Skipping", loop prevention works!**

### Test 4: Rapid Changes

**On NixOS:**
```bash
for i in {1..5}; do echo "Message $i" | wl-copy; sleep 1; done
```

All 5 messages should appear in sequence on macOS clipboard.

**Expected in logs:**
- NixOS log: 5× "📤 Sent to server"
- macOS log: 5× "📥 Received" and "✅ Applied"

**Verify on macOS:**
```bash
pbpaste
# Should show: Message 5
```

✅ **If final message is "Message 5", all changes synced!**

## 🔍 Troubleshooting

### "Still not working - NixOS → macOS doesn't sync"

1. **Make sure you're running the NEW version:**
   ```bash
   git log --oneline -1
   # Should show: 9125b06 Fix NixOS → macOS clipboard sync
   ```

2. **Verify old processes are REALLY stopped:**
   ```bash
   ps aux | grep native-sync
   # Should only show the grep command itself
   ```

3. **Check socat is actually being used:**
   ```bash
   # On NixOS
   ps aux | grep socat
   # Should see: socat ... TCP:10.211.55.2:9877

   # On macOS
   ps aux | grep socat
   # Should see: socat ... TCP-LISTEN:9877
   ```

4. **Check for error messages:**
   ```bash
   # NixOS
   tail -50 /tmp/native-sync-nixos.log | grep -i error

   # macOS
   tail -50 /tmp/native-sync-macos.log | grep -i error
   ```

### "macOS → NixOS stopped working"

The fix shouldn't have broken this direction. Check:
1. Is server running? `lsof -i :9877`
2. Is client connected? Check logs for "✅ Connected"
3. Try restarting both server and client

### "Clipboard changes too fast / misses some"

This is expected if you copy faster than the poll interval (200ms). Increase polling frequency:
```bash
NATIVE_SYNC_INTERVAL=0.1 ./scripts/native-sync-nixos.sh start
```

### "Lots of 'Skipping' messages"

This is normal! It means loop prevention is working. The clipboard change is detected locally after being applied from remote, but the hash matches so it's skipped.

## ✅ Success Criteria

You should see:
- ✅ NixOS → macOS: Copy on NixOS, instantly appears on macOS
- ✅ macOS → NixOS: Copy on macOS, instantly appears on NixOS
- ✅ Logs show "Applied to local clipboard" on both sides
- ✅ No continuous sync loops
- ✅ Rapid changes all sync correctly

## 📝 What Changed Technically

### Before (Broken):
```bash
socat ... | handle_server_communication
```
- One-way pipe
- stdout from handle_server_communication → discarded

### After (Fixed):
```bash
socat ... EXEC:"/bin/bash -c handle_server_communication",pty,stderr
```
- Bidirectional connection
- stdout from handle_server_communication → socat → server ✓
- stdin to handle_server_communication ← socat ← server ✓

### Hash Tracking:
- Changed from shell variables to files
- Allows background process to share state
- `$STATE_DIR/last_sent` - tracks outgoing clipboard
- `$STATE_DIR/last_received` - tracks incoming clipboard

## 🎉 If It Works...

Congratulations! You now have fully working bidirectional clipboard sync between NixOS VM and macOS host using simple bash scripts! 🎊

Consider setting up as a service so it starts automatically:
- See `scripts/RESTART_NATIVE_SYNC.md` for service setup instructions
- See `NATIVE_SYNC.md` for full documentation

---

**Commit:** `9125b06` - Fix NixOS → macOS clipboard sync (client stdout to server)
**Files changed:** `scripts/native-sync-nixos.sh`
**Lines changed:** +48, -19
