#!/usr/bin/env bash
# Diagnose xclip clipboard issues

echo "=== xclip Clipboard Diagnostic ==="
echo

# Check environment
echo "1. Environment:"
echo "   DISPLAY: ${DISPLAY:-<not set>}"
echo "   WAYLAND_DISPLAY: ${WAYLAND_DISPLAY:-<not set>}"
echo

# Check xclip availability
echo "2. xclip availability:"
if command -v xclip &> /dev/null; then
    echo "   ✓ xclip found: $(which xclip)"
else
    echo "   ✗ xclip not found"
    echo "   Install with: nix-shell -p xclip"
    exit 1
fi
echo

# Test 1: Simple write/read
echo "3. Test: Write then immediately read"
TEST_DATA="test-$(date +%s)"
echo "   Writing: $TEST_DATA"

# Write to clipboard (keep xclip alive in background)
echo "$TEST_DATA" | xclip -selection clipboard &
XCLIP_PID=$!
sleep 0.1

# Try to read
READ_DATA=$(xclip -o -selection clipboard 2>&1)
READ_STATUS=$?

echo "   Read status: $READ_STATUS"
echo "   Read data: '$READ_DATA'"

if [ "$READ_DATA" = "$TEST_DATA" ]; then
    echo "   ✓ SUCCESS: xclip read/write works!"
    kill $XCLIP_PID 2>/dev/null
else
    echo "   ✗ FAILED: Data doesn't match"
    echo "   This means xclip cannot maintain clipboard ownership"
    kill $XCLIP_PID 2>/dev/null
fi
echo

# Test 2: Check if clipboard persists
echo "4. Test: Check if clipboard persists after xclip exits"
echo "persistent-test" | xclip -selection clipboard
sleep 0.5  # Wait for xclip to exit

PERSISTENT=$(xclip -o -selection clipboard 2>&1)
if [ "$PERSISTENT" = "persistent-test" ]; then
    echo "   ✓ Clipboard persists (you have a clipboard manager)"
else
    echo "   ✗ Clipboard lost after xclip exits"
    echo "   You need a clipboard manager!"
    echo "   Common options:"
    echo "   - clipmenud (for dwm/i3)"
    echo "   - xfce4-clipman"
    echo "   - parcellite"
    echo "   - copyq"
fi
echo

# Test 3: Check what's currently in clipboard
echo "5. Current clipboard content:"
CURRENT=$(xclip -o -selection clipboard 2>&1)
if [ $? -eq 0 ] && [ -n "$CURRENT" ]; then
    echo "   ✓ Clipboard has content:"
    echo "   '${CURRENT:0:100}'"
else
    echo "   ✗ Clipboard is empty or error: $CURRENT"
fi
echo

# Test 4: List available targets
echo "6. Available clipboard targets:"
TARGETS=$(xclip -o -selection clipboard -t TARGETS 2>&1)
if [ $? -eq 0 ]; then
    echo "$TARGETS" | sed 's/^/   /'
else
    echo "   ✗ Cannot list targets: $TARGETS"
fi
echo

# Test 5: Try reading with different targets
echo "7. Testing different targets:"
for target in STRING UTF8_STRING TEXT text/plain; do
    echo -n "   $target: "
    RESULT=$(xclip -o -selection clipboard -t "$target" 2>&1)
    if [ $? -eq 0 ] && [ -n "$RESULT" ]; then
        echo "✓ ($( echo "$RESULT" | wc -c) bytes)"
    else
        echo "✗ ($(echo "$RESULT" | head -1))"
    fi
done
echo

# Test 6: Check for clipboard managers
echo "8. Checking for clipboard managers:"
for mgr in clipmenud xfce4-clipman parcellite copyq klipper; do
    if pgrep -x "$mgr" > /dev/null; then
        echo "   ✓ Found: $mgr (pid: $(pgrep -x "$mgr"))"
    fi
done
echo

# Summary
echo "=== DIAGNOSIS ==="
echo
if [ "$READ_DATA" = "$TEST_DATA" ] && [ "$PERSISTENT" = "persistent-test" ]; then
    echo "✓ xclip is working correctly!"
    echo
    echo "If clippy still can't read clipboard, the issue might be:"
    echo "  1. Timing - clipboard changes between checks"
    echo "  2. Format - clipboard contains non-text data"
    echo "  3. Permissions - clippy process doesn't have access"
elif [ "$READ_DATA" != "$TEST_DATA" ]; then
    echo "✗ xclip cannot maintain clipboard ownership"
    echo
    echo "SOLUTION: Install a clipboard manager"
    echo "  For NixOS, add to configuration.nix:"
    echo "  services.clipmenu.enable = true;"
    echo "  # or"
    echo "  services.greenclip.enable = true;"
elif [ "$PERSISTENT" != "persistent-test" ]; then
    echo "✗ Clipboard doesn't persist after xclip exits"
    echo
    echo "This is normal X11 behavior without a clipboard manager."
    echo "SOLUTION: Install and run a clipboard manager like:"
    echo "  - clipmenud"
    echo "  - parcellite"
    echo "  - copyq"
fi
echo
