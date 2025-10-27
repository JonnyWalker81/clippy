# Restart Native Sync (After Fix)

The native sync scripts have been fixed to properly support bidirectional communication.
Follow these steps to restart with the new version:

## 🛑 Step 1: Stop Old Processes

### On NixOS VM:
```bash
cd /path/to/clippy
./scripts/native-sync-nixos.sh stop

# Verify it stopped
ps aux | grep native-sync-nixos
# Kill any remaining processes
pkill -f native-sync-nixos
```

### On macOS Host:
```bash
cd /path/to/clippy
./scripts/native-sync-macos.sh stop

# Verify it stopped
ps aux | grep native-sync-macos
# Kill any remaining processes
pkill -f native-sync-macos
```

## 📦 Step 2: Install socat (Required)

### On macOS:
```bash
brew install socat
```

### On NixOS:
```bash
nix-shell -p socat

# Or add to configuration.nix:
environment.systemPackages = with pkgs; [
  socat
  wl-clipboard  # or xclip for X11
];
```

## 🚀 Step 3: Start Server (macOS)

```bash
cd /path/to/clippy
./scripts/native-sync-macos.sh start
```

You should see:
```
[2025-10-26 XX:XX:XX.XXX] 🚀 Starting native clipboard sync server on port 9877
[2025-10-26 XX:XX:XX.XXX] 📍 Log file: /tmp/native-sync-macos.log
[2025-10-26 XX:XX:XX.XXX] 📂 State directory: /tmp/native-sync-server
[2025-10-26 XX:XX:XX.XXX] ✓ Starting socat TCP server
```

## 🔗 Step 4: Start Client (NixOS)

```bash
cd /path/to/clippy
./scripts/native-sync-nixos.sh start
```

You should see:
```
[2025-10-26 XX:XX:XX.XXX] ✓ Using Wayland clipboard (wl-clipboard)
[2025-10-26 XX:XX:XX.XXX] 🔗 Connecting to server at 10.211.55.2:9877
[2025-10-26 XX:XX:XX.XXX] ✅ Connected to server
```

## ✅ Step 5: Test Bidirectional Sync

### Test 1: NixOS → macOS
1. On NixOS, copy some text: `echo "Test from NixOS" | wl-copy`
2. Check NixOS log: `tail -f /tmp/native-sync-nixos.log`
   - Should see: `🔍 Local clipboard changed` and `📤 Sent to server`
3. Check macOS log: `tail -f /tmp/native-sync-macos.log`
   - Should see: `📥 Received from client` and `✅ Applied to local clipboard`
4. On macOS, paste: `pbpaste`
   - Should show "Test from NixOS"

### Test 2: macOS → NixOS
1. On macOS, copy some text: `echo "Test from macOS" | pbcopy`
2. Check macOS log: `tail -f /tmp/native-sync-macos.log`
   - Should see: `🔍 Local clipboard changed` and `📤 Sent to client`
3. Check NixOS log: `tail -f /tmp/native-sync-nixos.log`
   - Should see: `📥 Received from server` and `✅ Applied to local clipboard`
4. On NixOS, paste: `wl-paste`
   - Should show "Test from macOS"

## 🔍 Step 6: Verify with Health Check

```bash
./scripts/native-sync-check.sh
```

Should show:
- ✓ Process running
- ✓ Server listening / Server reachable
- ✓ Clipboard tools available
- Recent log entries showing sync activity

## 📊 Monitor Logs in Real-Time

### macOS:
```bash
tail -f /tmp/native-sync-macos.log
```

### NixOS:
```bash
tail -f /tmp/native-sync-nixos.log
```

## 🐛 Troubleshooting

### "socat not found"
- Install socat (see Step 2)

### "Cannot connect to server"
- Make sure macOS server is running first
- Check firewall on macOS
- Verify IP address: `ifconfig | grep inet` (macOS)
- Test connectivity: `nc -zv 10.211.55.2 9877` (NixOS)

### "No logs appearing"
- Make sure you killed all old processes
- Check VERBOSE=1 is set (default)
- Look for processes: `ps aux | grep native-sync`

### "Clipboard not syncing"
- Check logs for errors
- Verify clipboard tools work manually:
  - macOS: `echo "test" | pbcopy && pbpaste`
  - NixOS: `echo "test" | wl-copy && wl-paste`
- Make sure DISPLAY/WAYLAND_DISPLAY is set

### "Sync loops (same content repeatedly)"
- This should be fixed now with dual hash tracking
- If it still happens, check logs to see which hashes are being compared

## 🎯 What Changed

### Before (Broken):
- Complex named pipe architecture
- NixOS client sent data but server couldn't receive it properly
- Bidirectional communication didn't work

### After (Fixed):
- Simplified socat EXEC handler on server
- Proper stdin/stdout pipe handling on client
- Each handler instance polls local clipboard AND reads from remote
- Dual hash tracking prevents sync loops
- **Both directions now work! 🎉**

## 📝 Key Requirements

1. **socat is now REQUIRED** on both macOS and NixOS
2. Stop old processes before starting new ones
3. Start server (macOS) before client (NixOS)
4. Monitor logs to verify bidirectional sync

## 🔄 Restart Services

If running as services (launchd/systemd), update and restart:

### macOS:
```bash
launchctl stop com.clippy.native-sync
launchctl start com.clippy.native-sync
```

### NixOS:
```bash
systemctl --user restart native-sync-nixos
```

---

**Note**: The native sync scripts use port **9877** (different from the Rust daemon which uses **9876**). Both can run simultaneously if needed.
