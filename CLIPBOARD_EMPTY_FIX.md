# Fix: "Clipboard is empty" on NixOS

## The Problem

You're seeing:
```
INFO Clipboard is empty
INFO 🔄 Monitor active (iteration 10, last_checksum: None)
INFO Clipboard is empty
```

Even after copying text. This means `arboard` can't read your clipboard content.

## Root Cause

**95% chance**: You're copying to the wrong clipboard selection!

Linux has **THREE** clipboard selections:
1. **PRIMARY** - Middle-click paste (what most apps copy to by default!)
2. **CLIPBOARD** - Ctrl+V paste (what arboard reads from)
3. **SECONDARY** - Rarely used

When you select text in many Linux apps, it goes to **PRIMARY**, not **CLIPBOARD**!

## Immediate Fix - Test with New Tool

```bash
cd ~/Repositories/clippy
git pull
cargo build --release

# Run diagnostic test
./target/release/test_clipboard
```

This will:
1. Check environment variables
2. Test clipboard write
3. Test clipboard read
4. Show exactly what's wrong

## Manual Testing

### Test 1: Can you read what `arboard` reads?

```bash
# Copy using xclip to CLIPBOARD selection (what arboard uses)
echo "test from xclip" | xclip -selection clipboard

# Read it back (this is what arboard does)
xclip -o -selection clipboard

# Should show: "test from xclip"
```

If this works, then run clippy:
```bash
./target/release/clippy -v start --client
# Should immediately detect the clipboard content!
```

### Test 2: What's in your PRIMARY selection?

```bash
# Read from PRIMARY (what mouse selection uses)
xclip -o -selection primary

# This might show content you "copied" by selecting!
```

## The Real Fix: Copy to CLIPBOARD

You need to ensure text goes to the **CLIPBOARD** selection, not PRIMARY.

### Method 1: Use Ctrl+C (Not Just Selection)

In most GUI apps:
1. Select text
2. **Press Ctrl+C** (or Cmd+C)
3. This copies to CLIPBOARD selection

Just selecting text only copies to PRIMARY!

### Method 2: Configure Your Terminal

If using a terminal emulator, configure it to copy to CLIPBOARD:

**For most terminals:**
- Check settings/preferences
- Look for "Selection Copies to Clipboard" or similar
- Enable "Copy on select to clipboard"

### Method 3: Test with xclip

```bash
# Always use -selection clipboard
echo "test" | xclip -selection clipboard

# NOT just: echo "test" | xclip
# (That goes to PRIMARY!)
```

## Running the Test

### Step 1: Test clipboard tool
```bash
./target/release/test_clipboard
```

**Expected successful output:**
```
=== Clipboard Access Test ===

Environment:
  DISPLAY: Ok(":0")
  ...

Creating clipboard instance...
✓ Clipboard created successfully

Writing test text to clipboard...
✓ Write successful: clippy-test-1729796400

Reading from clipboard...
✓ Read successful: clippy-test-1729796400
✓ Content matches what we wrote!
```

### Step 2: Manual copy to CLIPBOARD
```bash
# Copy to CLIPBOARD selection
echo "hello from nixos" | xclip -selection clipboard
```

### Step 3: Run clippy with RUST_LOG=debug
```bash
RUST_LOG=debug ./target/release/clippy -v start --client
```

**Now you should see:**
```
DEBUG Found text in clipboard: 17 bytes
Current clipboard checksum: abc12345
⚡ CHECKSUM CHANGED! Old: None, New: abc12345
🔍 Reading clipboard content...
DEBUG Found text in clipboard: 17 bytes
🔍 Detected LOCAL clipboard change (type: text, checksum: abc12345)
📋 Content preview: hello from nixos
```

## If Still Showing "Clipboard is empty"

### Check 1: What error does arboard give?

With `RUST_LOG=debug`, you should see:
```
WARN Failed to get text from clipboard: <error message>
WARN This usually means:
WARN   - Clipboard is genuinely empty
WARN   - Or clipboard has unsupported format
WARN   - Or wrong clipboard selection (PRIMARY vs CLIPBOARD)
```

### Check 2: Manually verify clipboard has content

```bash
# Put something in clipboard
echo "test123" | xclip -selection clipboard

# Verify it's there
xclip -o -selection clipboard
# Should show: test123

# Now run clippy
RUST_LOG=debug ./target/release/clippy -v start --client
# Should immediately detect it
```

### Check 3: Is xclip working?

```bash
# Test xclip read/write
echo "test" | xclip -selection clipboard && xclip -o -selection clipboard

# If this doesn't show "test", xclip is broken
# Reinstall:
nix-shell -p xclip
```

## Common Scenarios

### Scenario A: Selecting Text in Terminal

**Problem:** You select text with mouse, but clippy doesn't detect it.

**Reason:** Text selection goes to PRIMARY, not CLIPBOARD!

**Fix:** After selecting, press **Ctrl+Shift+C** to copy to CLIPBOARD.

### Scenario B: Copying in GUI App

**Problem:** You copy in Firefox/Chrome but clippy doesn't detect it.

**Reason:** Need to ensure app copies to CLIPBOARD selection.

**Fix:** Use Ctrl+C (not just right-click → copy in some apps).

### Scenario C: Text in Clipboard but Arboard Can't Read

**Problem:** `xclip -o -selection clipboard` shows content, but clippy says empty.

**Reason:** Arboard might have permission or library issues.

**Test:**
```bash
# Run test tool
./target/release/test_clipboard

# Should show the specific error
```

## Ultimate Test Script

Run this to test everything:

```bash
#!/bin/bash
echo "=== Clipboard Debug Test ==="
echo

echo "1. Put test data in clipboard..."
echo "clippy-test-$(date +%s)" | xclip -selection clipboard

echo "2. Verify with xclip..."
CLIP_CONTENT=$(xclip -o -selection clipboard)
echo "   xclip shows: $CLIP_CONTENT"

echo "3. Test with test_clipboard tool..."
./target/release/test_clipboard

echo "4. Test with clippy (run for 5 seconds)..."
timeout 5 RUST_LOG=debug ./target/release/clippy -v start --client 2>&1 | grep -E "(clipboard|CHECKSUM|Found)"

echo
echo "=== Results ==="
echo "If you see 'Found text in clipboard' in step 4, it's working!"
echo "If not, check the errors above."
```

## Quick Reference

| Clipboard Selection | Used By | How to Copy |
|---------------------|---------|-------------|
| PRIMARY | Mouse selection | Just select text |
| CLIPBOARD | Ctrl+V paste | Ctrl+C or Cmd+C |
| SECONDARY | Rarely used | - |

**Arboard reads from:** CLIPBOARD
**You need to copy to:** CLIPBOARD (use Ctrl+C!)

## Still Not Working?

Share these outputs:

```bash
# 1. Test tool output
./target/release/test_clipboard

# 2. Manual xclip test
echo "manual-test" | xclip -selection clipboard && xclip -o -selection clipboard

# 3. Clippy with debug logging (after step 2)
RUST_LOG=debug ./target/release/clippy -v start --client 2>&1 | head -50

# 4. Environment
env | grep -E "(DISPLAY|WAYLAND|XDG)"
```

This will show exactly where the problem is!
