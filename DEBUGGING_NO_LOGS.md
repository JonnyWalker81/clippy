# Debugging: No Logs When Copying on NixOS

## The Problem

When you copy something on NixOS VM, you see **NO logs at all** - neither detection logs nor sync logs. This means the clipboard monitor isn't detecting changes.

## Step-by-Step Diagnosis

### STEP 1: Test Clipboard Access on NixOS

**Run this diagnostic script:**
```bash
cd ~/Repositories/clippy
./scripts/test-clipboard.sh
```

This will check:
1. DISPLAY environment variable
2. Clipboard tools (xclip, wl-clipboard)
3. Ability to read/write clipboard

**Expected output if working:**
```
=== Clipboard Test for NixOS ===

1. Environment Check:
   DISPLAY: :0
   ...

2. Clipboard Tools Check:
   ✓ xclip found: /nix/store/.../bin/xclip

3. Testing Clipboard Write:
   ✓ Write successful

4. Testing Clipboard Read:
   ✓ Read successful: clippy-test-1234567890
   ✓ Content matches!

5. Checking arboard requirements:
   ✓ arboard should work (display + tools present)

=== SUMMARY ===
✓ Clipboard should work!
```

**If you see errors**, follow the fixes below.

### STEP 2: Rebuild and Run with Ultra-Verbose Logging

**On NixOS, rebuild:**
```bash
cd ~/Repositories/clippy
git pull
cargo build --release
```

**Run with verbose logging:**
```bash
./target/release/clippy -v start --client
```

**Expected logs (if working):**
```
INFO Starting in client-only mode
INFO Connecting to server at 10.211.55.1:9876...
INFO Connected to server
INFO Authentication successful
🚀 Initializing clipboard manager...
✓ Clipboard manager initialized successfully
✓ Starting clipboard monitor (checking every 500ms)
🔄 Monitor loop started - waiting for clipboard changes...
🔄 Monitor active (iteration 10, last_checksum: None)
Current clipboard checksum: abc12345
🔄 Monitor active (iteration 20, last_checksum: Some("abc12345"))
Current clipboard checksum: abc12345
```

**When you copy something, you should see:**
```
⚡ CHECKSUM CHANGED! Old: Some("abc12345"), New: def67890
🔍 Reading clipboard content...
🔍 Detected LOCAL clipboard change (type: text, checksum: def67890)
📋 Content preview: your copied text here
📤 Sending clipboard update to server...
✓ Clipboard update sent to server
```

### STEP 3: Diagnose Based on Logs

#### Case A: "Failed to initialize clipboard manager"

**Logs show:**
```
❌ Failed to initialize clipboard manager: ...
This usually means:
  - X11: xclip or xsel not installed
  - Wayland: wl-clipboard not installed
  - No DISPLAY environment variable set
```

**Fix 1 - Install clipboard tools:**

**For X11 (most common):**
```bash
# Temporary (current session):
nix-shell -p xclip

# Permanent (add to configuration.nix):
environment.systemPackages = with pkgs; [
  xclip
];
```

**For Wayland:**
```bash
# Temporary:
nix-shell -p wl-clipboard

# Permanent (add to configuration.nix):
environment.systemPackages = with pkgs; [
  wl-clipboard
];
```

**Fix 2 - Set DISPLAY variable:**
```bash
# Check if DISPLAY is set
echo $DISPLAY

# If empty, set it:
export DISPLAY=:0

# Make permanent (add to ~/.bashrc or ~/.zshrc):
echo 'export DISPLAY=:0' >> ~/.bashrc
```

**Fix 3 - Run in graphical session:**

Clippy MUST run in the same session as your desktop environment. If running over SSH:
```bash
# SSH won't work for clipboard access!
# You need to run clippy directly in the GUI terminal
```

#### Case B: Monitor starts but no "Monitor active" logs

**Logs show:**
```
✓ Starting clipboard monitor (checking every 500ms)
🔄 Monitor loop started - waiting for clipboard changes...
[nothing else]
```

This means the monitor loop isn't running. Check if the process crashed:
```bash
ps aux | grep clippy
# Should show running process
```

If not running, check for panic messages in logs.

#### Case C: Monitor active but no change detection

**Logs show:**
```
🔄 Monitor active (iteration 10, last_checksum: None)
Current clipboard checksum: abc12345
🔄 Monitor active (iteration 20, last_checksum: Some("abc12345"))
Current clipboard checksum: abc12345
[checksum never changes]
```

This means:
1. Clipboard access works
2. Monitor is polling
3. But checksum isn't changing when you copy

**Possible causes:**

**A) Copying to wrong clipboard selection:**

Linux has multiple clipboards:
- PRIMARY (middle-click paste)
- CLIPBOARD (Ctrl+V paste)

Make sure you're copying to CLIPBOARD:
```bash
# Test copy to CLIPBOARD
echo "test" | xclip -selection clipboard

# Verify
xclip -o -selection clipboard
```

**B) Checksum calculation issue:**

The same content has the same checksum. Try copying **different** content:
```bash
echo "test1" | xclip -selection clipboard
# Wait 1 second, check logs
echo "test2" | xclip -selection clipboard
# Wait 1 second, check logs
```

**C) Clipboard content not supported:**

Currently supported:
- Text ✓
- Images ✓
- HTML ✓

Try copying plain text first:
```bash
echo "Hello World" | xclip -selection clipboard
```

#### Case D: Change detected but content read fails

**Logs show:**
```
⚡ CHECKSUM CHANGED! Old: None, New: abc12345
🔍 Reading clipboard content...
❌ Failed to read clipboard content: ...
```

This means detection works but reading fails. The error message will give specifics.

Possible issues:
- Content too large (check max_content_size_mb in config)
- Unsupported format
- Clipboard access lost between checksum and content read

### STEP 4: Manual Clipboard Test

**Test if arboard library can access clipboard:**

Create a test file:
```bash
cat > /tmp/test_clipboard.rs << 'EOF'
use arboard::Clipboard;

fn main() {
    println!("Attempting to create clipboard...");
    let mut clipboard = match Clipboard::new() {
        Ok(c) => {
            println!("✓ Clipboard created successfully");
            c
        }
        Err(e) => {
            eprintln!("✗ Failed to create clipboard: {}", e);
            return;
        }
    };

    println!("\nAttempting to read clipboard...");
    match clipboard.get_text() {
        Ok(text) => {
            println!("✓ Read successful: {}", text);
        }
        Err(e) => {
            eprintln!("✗ Failed to read: {}", e);
        }
    }

    println!("\nAttempting to write clipboard...");
    match clipboard.set_text("test from rust") {
        Ok(_) => {
            println!("✓ Write successful");
        }
        Err(e) => {
            eprintln!("✗ Failed to write: {}", e);
        }
    }
}
EOF

# Build and run
rustc /tmp/test_clipboard.rs -o /tmp/test_clipboard \
  --edition 2021 \
  --extern arboard=$(find ~/.cargo -name "libarboard*.rlib" | head -1)

# Or using cargo:
cd /tmp
cargo new clipboard_test
cd clipboard_test
echo 'arboard = "3.4"' >> Cargo.toml
cat > src/main.rs << 'EOF'
use arboard::Clipboard;

fn main() {
    println!("Testing clipboard access...");
    let mut clipboard = Clipboard::new().expect("Failed to create clipboard");

    println!("Current clipboard: {:?}", clipboard.get_text());

    clipboard.set_text("test").expect("Failed to set");
    println!("✓ Clipboard test successful!");
}
EOF

cargo run
```

### STEP 5: Check System Configuration

**Verify you're in a graphical session:**
```bash
# Should show your desktop session
echo $XDG_SESSION_TYPE  # "x11" or "wayland"

# Should show your display
echo $DISPLAY           # ":0" or ":1" etc

# Check if X server is running
ps aux | grep X
```

**Verify clipboard tools work manually:**
```bash
# Copy with xclip
echo "manual test" | xclip -selection clipboard

# Read with xclip
xclip -o -selection clipboard

# Should show: "manual test"
```

### STEP 6: Common Fixes Summary

| Symptom | Fix |
|---------|-----|
| "Failed to initialize clipboard manager" | Install xclip or wl-clipboard |
| No DISPLAY | Run in graphical session or `export DISPLAY=:0` |
| Running over SSH | Must run in local GUI terminal, not SSH |
| Monitor not starting | Check process is still running: `ps aux \| grep clippy` |
| Checksum never changes | Copy to CLIPBOARD selection, not PRIMARY |
| Content read fails | Check content size, try plain text first |

### STEP 7: Full Diagnostic Output

**Please run and share these outputs:**

```bash
# 1. Clipboard test
./scripts/test-clipboard.sh > /tmp/clipboard-test.txt 2>&1

# 2. Environment
env | grep -E "(DISPLAY|WAYLAND|XDG)" > /tmp/env.txt

# 3. Clippy logs (run for 10 seconds, copy something during this time)
timeout 10 ./target/release/clippy -v start --client > /tmp/clippy-logs.txt 2>&1

# 4. System info
uname -a > /tmp/sysinfo.txt
ps aux | grep -E "(X|wayland|clippy)" >> /tmp/sysinfo.txt

# Share these files
cat /tmp/clipboard-test.txt
echo "---"
cat /tmp/env.txt
echo "---"
cat /tmp/clippy-logs.txt
echo "---"
cat /tmp/sysinfo.txt
```

## Quick Checklist

Before running clippy, ensure:
- [ ] Running in graphical session (not SSH)
- [ ] DISPLAY or WAYLAND_DISPLAY is set
- [ ] xclip (X11) or wl-clipboard (Wayland) installed
- [ ] Can copy/paste with xclip manually
- [ ] Clippy rebuilt with latest code
- [ ] Running with -v flag for verbose logs

## Most Likely Issue

**90% of "no logs" cases are:** Missing xclip or DISPLAY not set

**Quick fix:**
```bash
# Install xclip in dev shell
nix develop

# Verify xclip works
echo "test" | xclip -selection clipboard && xclip -o -selection clipboard

# If that works, clippy should work too
./target/release/clippy -v start --client
```

## Still Not Working?

If you've tried everything above and still no logs, please share:

1. Output of `./scripts/test-clipboard.sh`
2. Output of `clippy -v start --client` (first 50 lines)
3. Output of `echo $DISPLAY $XDG_SESSION_TYPE`
4. Output of `xclip -o -selection clipboard` after manually copying

This will help identify the exact issue!
