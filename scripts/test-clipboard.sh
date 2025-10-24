#!/usr/bin/env bash
# Test clipboard functionality on Linux/NixOS

echo "=== Clipboard Test for NixOS ==="
echo

# Check environment
echo "1. Environment Check:"
echo "   DISPLAY: ${DISPLAY:-<not set>}"
echo "   WAYLAND_DISPLAY: ${WAYLAND_DISPLAY:-<not set>}"
echo "   XDG_SESSION_TYPE: ${XDG_SESSION_TYPE:-<not set>}"
echo

# Check for clipboard tools
echo "2. Clipboard Tools Check:"
if command -v xclip &> /dev/null; then
    echo "   ✓ xclip found: $(which xclip)"
else
    echo "   ✗ xclip not found"
fi

if command -v xsel &> /dev/null; then
    echo "   ✓ xsel found: $(which xsel)"
else
    echo "   ✗ xsel not found"
fi

if command -v wl-copy &> /dev/null; then
    echo "   ✓ wl-copy found: $(which wl-copy)"
else
    echo "   ✗ wl-copy not found"
fi

if command -v wl-paste &> /dev/null; then
    echo "   ✓ wl-paste found: $(which wl-paste)"
else
    echo "   ✗ wl-paste not found"
fi
echo

# Test clipboard write
echo "3. Testing Clipboard Write:"
TEST_STRING="clippy-test-$(date +%s)"
echo "   Writing test string: $TEST_STRING"

if [ -n "$WAYLAND_DISPLAY" ]; then
    echo "   Using Wayland (wl-copy)..."
    if echo "$TEST_STRING" | wl-copy 2>/dev/null; then
        echo "   ✓ Write successful"
    else
        echo "   ✗ Write failed"
    fi
elif [ -n "$DISPLAY" ]; then
    echo "   Using X11 (xclip)..."
    if echo "$TEST_STRING" | xclip -selection clipboard 2>/dev/null; then
        echo "   ✓ Write successful"
    else
        echo "   ✗ Write failed"
    fi
else
    echo "   ✗ No DISPLAY or WAYLAND_DISPLAY set"
fi
echo

# Test clipboard read
echo "4. Testing Clipboard Read:"
if [ -n "$WAYLAND_DISPLAY" ]; then
    echo "   Using Wayland (wl-paste)..."
    CLIPBOARD_CONTENT=$(wl-paste 2>/dev/null)
elif [ -n "$DISPLAY" ]; then
    echo "   Using X11 (xclip)..."
    CLIPBOARD_CONTENT=$(xclip -o -selection clipboard 2>/dev/null)
else
    echo "   ✗ Cannot read clipboard - no display"
    CLIPBOARD_CONTENT=""
fi

if [ -n "$CLIPBOARD_CONTENT" ]; then
    echo "   ✓ Read successful: $CLIPBOARD_CONTENT"
    if [ "$CLIPBOARD_CONTENT" = "$TEST_STRING" ]; then
        echo "   ✓ Content matches!"
    else
        echo "   ⚠ Content doesn't match (might be old clipboard data)"
    fi
else
    echo "   ✗ Read failed or clipboard empty"
fi
echo

# Check if arboard can work
echo "5. Checking arboard requirements:"
if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
    if command -v xclip &> /dev/null || command -v wl-copy &> /dev/null; then
        echo "   ✓ arboard should work (display + tools present)"
    else
        echo "   ✗ arboard needs xclip (X11) or wl-clipboard (Wayland)"
    fi
else
    echo "   ✗ arboard needs DISPLAY or WAYLAND_DISPLAY environment variable"
fi
echo

# Summary
echo "=== SUMMARY ==="
echo
if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
    if command -v xclip &> /dev/null || command -v wl-copy &> /dev/null; then
        echo "✓ Clipboard should work!"
        echo
        echo "If clippy still can't access clipboard:"
        echo "  1. Make sure you're running in the same session (same DISPLAY)"
        echo "  2. Try: export DISPLAY=:0"
        echo "  3. Check clippy logs for specific errors"
    else
        echo "❌ Missing clipboard tools!"
        echo
        echo "Install clipboard tools:"
        if [ -n "$WAYLAND_DISPLAY" ]; then
            echo "  nix-shell -p wl-clipboard"
            echo "  or add to configuration.nix:"
            echo "  environment.systemPackages = [ pkgs.wl-clipboard ];"
        else
            echo "  nix-shell -p xclip"
            echo "  or add to configuration.nix:"
            echo "  environment.systemPackages = [ pkgs.xclip ];"
        fi
    fi
else
    echo "❌ No display server detected!"
    echo
    echo "Make sure you're running in a graphical session"
    echo "Or set DISPLAY environment variable:"
    echo "  export DISPLAY=:0"
fi
echo
