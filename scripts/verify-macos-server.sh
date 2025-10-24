#!/usr/bin/env bash
# Verify clippy server status on macOS host

echo "=== Clippy Server Verification (macOS) ==="
echo

# Step 1: Check if process is running
echo "1. Checking if clippy process is running..."
if pgrep -f "clippy.*start" > /dev/null; then
    echo "   ✓ Clippy process found:"
    ps aux | grep -E "clippy.*start" | grep -v grep | sed 's/^/     /'
    echo

    # Get PID
    CLIPPY_PID=$(pgrep -f "clippy.*start" | head -1)
    echo "   PID: $CLIPPY_PID"
else
    echo "   ❌ No clippy process running"
    echo "   Start with: clippy start --server"
    exit 1
fi
echo

# Step 2: Check what ports clippy is listening on
echo "2. Checking listening ports..."
if command -v lsof &> /dev/null; then
    echo "   Ports clippy is listening on:"
    if lsof -nP -p "$CLIPPY_PID" -a -i TCP -s TCP:LISTEN 2>/dev/null | grep -v COMMAND; then
        LISTEN_OUTPUT=$(lsof -nP -p "$CLIPPY_PID" -a -i TCP -s TCP:LISTEN 2>/dev/null | grep -v COMMAND)
        echo "$LISTEN_OUTPUT" | sed 's/^/     /'

        # Check if listening on 0.0.0.0 or specific interface
        if echo "$LISTEN_OUTPUT" | grep -q "\*:9876"; then
            echo "   ✓ Listening on all interfaces (0.0.0.0:9876) - GOOD!"
        elif echo "$LISTEN_OUTPUT" | grep -q "127.0.0.1:9876"; then
            echo "   ❌ WARNING: Only listening on localhost (127.0.0.1:9876)"
            echo "   This will NOT work for VM connections!"
            echo "   Fix: Update config to use host = \"0.0.0.0\""
        fi
    else
        echo "   ❌ Clippy is not listening on any TCP ports"
    fi
else
    echo "   ⚠ lsof not found, trying netstat..."
    if netstat -an | grep -E "\.9876.*LISTEN" > /dev/null; then
        echo "   Port 9876 is listening:"
        netstat -an | grep -E "\.9876.*LISTEN" | sed 's/^/     /'
    else
        echo "   ❌ Port 9876 is not listening"
    fi
fi
echo

# Step 3: Check config
echo "3. Checking configuration..."
if [ -f ~/.config/clippy/config.toml ]; then
    echo "   Config file: ~/.config/clippy/config.toml"
    echo
    SERVER_HOST=$(grep -A 3 "\[server\]" ~/.config/clippy/config.toml | grep "host" | cut -d'"' -f2)
    SERVER_PORT=$(grep -A 3 "\[server\]" ~/.config/clippy/config.toml | grep "port" | awk '{print $3}')

    echo "   [server]"
    echo "   host = \"$SERVER_HOST\""
    echo "   port = $SERVER_PORT"
    echo

    if [ "$SERVER_HOST" = "0.0.0.0" ]; then
        echo "   ✓ Server host is 0.0.0.0 - accessible from VM"
    else
        echo "   ❌ Server host is $SERVER_HOST - NOT accessible from VM"
        echo "   Change to: host = \"0.0.0.0\""
    fi

    if [ "$SERVER_PORT" = "9876" ]; then
        echo "   ✓ Server port is 9876 - default"
    else
        echo "   ⚠ Server port is $SERVER_PORT - non-standard"
    fi
else
    echo "   ❌ Config file not found at ~/.config/clippy/config.toml"
fi
echo

# Step 4: Show all network interfaces
echo "4. Network interfaces and IPs..."
echo "   VMs should connect to one of these IPs:"
ifconfig | grep -E "inet " | grep -v 127.0.0.1 | awk '{print "     " $2}'
echo

# Step 5: Check firewall status
echo "5. Checking macOS firewall..."
if [ -f /usr/libexec/ApplicationFirewall/socketfilterfw ]; then
    FW_STATUS=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate)
    echo "   Firewall: $FW_STATUS"

    if echo "$FW_STATUS" | grep -q "enabled"; then
        echo "   ⚠ Firewall is enabled - may block connections"
        echo "   Check: System Preferences → Security & Privacy → Firewall"
        echo "   Allow: clippy or port 9876"
    fi
fi
echo

# Step 6: Test local connection
echo "6. Testing local connection..."
if timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/9876" 2>/dev/null; then
    echo "   ✓ Can connect to localhost:9876"
else
    echo "   ❌ Cannot connect to localhost:9876"
    echo "   Server may not be running or not listening on port 9876"
fi
echo

# Step 7: Test connection from all interfaces
echo "7. Testing accessibility from network interfaces..."
for IP in $(ifconfig | grep -E "inet " | grep -v 127.0.0.1 | awk '{print $2}'); do
    echo -n "   Testing $IP:9876... "
    if timeout 2 bash -c "cat < /dev/null > /dev/tcp/$IP/9876" 2>/dev/null; then
        echo "✓ ACCESSIBLE"
    else
        echo "✗ NOT ACCESSIBLE"
    fi
done
echo

# Summary
echo "=== SUMMARY ==="
echo
if pgrep -f "clippy.*start" > /dev/null && \
   [ "$SERVER_HOST" = "0.0.0.0" ] && \
   timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/9876" 2>/dev/null; then
    echo "✓ Server appears to be running correctly!"
    echo
    echo "On NixOS VM, use one of these IPs for server_host:"
    ifconfig | grep -E "inet " | grep -v 127.0.0.1 | awk '{print "  - " $2}'
else
    echo "❌ Server has issues. Check the details above."
    echo
    echo "Common fixes:"
    echo "  1. Restart server: pkill clippy && clippy start --server"
    echo "  2. Check config: cat ~/.config/clippy/config.toml"
    echo "  3. Ensure host = \"0.0.0.0\" in config"
    echo "  4. Check firewall settings"
fi
echo
