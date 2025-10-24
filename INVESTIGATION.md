# Investigating "Connection Refused" When Server Is Running

## The Problem

You're seeing:
```
ERROR Client error: Connection refused (os error 111)
```

But you say the server IS running on macOS. Let's investigate systematically.

## Step-by-Step Investigation

### STEP 1: Verify Server is Actually Running on macOS

**On macOS host**, run:

```bash
# Check if clippy process exists
ps aux | grep clippy

# Check what ports are being used
lsof -i :9876
# or
netstat -an | grep 9876

# Run the verification script
./scripts/verify-macos-server.sh
```

**Expected output if server is running correctly:**
```
clippy           12345 user   *:9876 (LISTEN)
```

**If you see `127.0.0.1:9876` instead of `*:9876`:**
- ❌ Server is only listening on localhost
- ✗ VM cannot connect
- **FIX**: Change config to `host = "0.0.0.0"`

### STEP 2: Check Server Configuration on macOS

**On macOS host**, check:

```bash
cat ~/.config/clippy/config.toml
```

**CORRECT config:**
```toml
[server]
host = "0.0.0.0"  # ✓ Listen on ALL interfaces
port = 9876
```

**WRONG config (will cause "connection refused"):**
```toml
[server]
host = "127.0.0.1"  # ✗ Only localhost - VM cannot connect!
port = 9876
```

### STEP 3: Identify the Correct macOS IP

**From NixOS VM**, run the diagnostic:

```bash
./scripts/diagnose-connection.sh
```

This will:
1. Find all possible macOS IPs
2. Test which ones are reachable
3. Test which ones have port 9876 open
4. Tell you exactly which IP to use

**Manual method:**

```bash
# On NixOS VM - find gateway
ip route | grep default
# Output: default via 10.211.55.1 dev enp0s5

# Test connectivity
ping -c 2 10.211.55.1

# Test port 9876
nc -zv 10.211.55.1 9876
# or
timeout 2 bash -c "cat < /dev/null > /dev/tcp/10.211.55.1/9876" && echo "OPEN" || echo "CLOSED"
```

### STEP 4: Common Issues and Fixes

#### Issue A: Server Bound to Wrong Interface

**Symptom:**
- Server runs on macOS
- `lsof` shows `127.0.0.1:9876` (not `*:9876`)
- Connection refused from VM

**Fix:**
```bash
# On macOS - edit config
nano ~/.config/clippy/config.toml

# Change:
[server]
host = "0.0.0.0"  # NOT 127.0.0.1

# Restart server
pkill clippy
clippy start --server
```

#### Issue B: Wrong IP Address

**Symptom:**
- Server runs correctly
- But VM uses wrong IP

**Fix:**
```bash
# On NixOS VM - find correct IP
ip route | grep default  # Usually 10.211.55.1 or 10.211.55.2

# Test both:
nc -zv 10.211.55.1 9876
nc -zv 10.211.55.2 9876

# Update config with the one that works
nano ~/.config/clippy/config.toml
[client]
server_host = "10.211.55.1"  # Use the working IP
```

#### Issue C: macOS Firewall Blocking

**Symptom:**
- Server runs, bound to 0.0.0.0
- Ping works
- But port 9876 blocked

**Fix:**
1. System Preferences → Security & Privacy → Firewall
2. Click "Firewall Options"
3. Add clippy to allowed apps
4. Or temporarily disable firewall to test:
   ```bash
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off
   # Test connection
   # Re-enable:
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
   ```

#### Issue D: Wrong Port

**Symptom:**
- Everything looks right but still fails

**Check:**
```bash
# On macOS - verify port
lsof -i :9876  # Should show clippy

# On NixOS - verify config
grep server_port ~/.config/clippy/config.toml  # Should be 9876
```

### STEP 5: Nuclear Option - Fresh Start

If nothing works, start fresh:

**On macOS:**
```bash
# Kill any running instances
pkill clippy

# Remove config
rm -rf ~/.config/clippy

# Create fresh config
mkdir -p ~/.config/clippy
cat > ~/.config/clippy/config.toml << 'EOF'
[server]
host = "0.0.0.0"
port = 9876

[client]
server_host = "127.0.0.1"
server_port = 9876
auto_connect = true

[storage]
max_history = 1000
max_content_size_mb = 10

[sync]
interval_ms = 500
retry_delay_ms = 5000
heartbeat_interval_ms = 30000
EOF

# Start server with verbose logging
clippy -v start --server
```

**On NixOS:**
```bash
# Kill any running instances
pkill clippy

# Run diagnostic to find macOS
./scripts/diagnose-connection.sh

# It will tell you the correct IP and offer to fix config
# Then start client:
clippy -v start --client
```

## Detailed Diagnostics

### Test Connection Step by Step

**From NixOS VM:**

```bash
# 1. Can you reach macOS at all?
ping -c 2 10.211.55.1
# If fails: Network issue, check VM network settings

# 2. Can you reach port 9876 on macOS?
nc -zv 10.211.55.1 9876
# If fails but ping works: Firewall or server not listening

# 3. Test with telnet (shows more info)
telnet 10.211.55.1 9876
# If connects: Server is working!
# If "Connection refused": Server not listening on that interface
# If timeout: Firewall blocking

# 4. Try alternative IPs
nc -zv 10.211.55.2 9876
nc -zv 10.37.129.1 9876
nc -zv 10.37.129.2 9876
```

### Check Server Logs

**On macOS:**

```bash
# Start with verbose logging
clippy -v start --server

# Should see:
# INFO Clipboard server listening on 0.0.0.0:9876
#                                     ^^^^^^^^^^^
#                              This is crucial!

# If you see:
# INFO Clipboard server listening on 127.0.0.1:9876
#                                     ^^^^^^^^^^^^^
# This is WRONG - change config to 0.0.0.0
```

### Check Client Logs

**On NixOS VM:**

```bash
# Start with verbose logging
clippy -v start --client

# Should see:
# INFO Connecting to server at 10.211.55.1:9876...
# INFO Connected to server
# INFO Authentication successful

# If you see:
# ERROR Connection refused
# Then the IP or server is wrong
```

## Quick Diagnosis Commands

### On macOS (copy and paste):
```bash
echo "=== MACOS SERVER DIAGNOSTICS ===" && \
ps aux | grep "[c]lippy" && \
echo "---" && \
lsof -i :9876 && \
echo "---" && \
ifconfig | grep "inet " | grep -v 127.0.0.1 && \
echo "---" && \
cat ~/.config/clippy/config.toml | grep -A 2 "\[server\]"
```

### On NixOS VM (copy and paste):
```bash
echo "=== NIXOS CLIENT DIAGNOSTICS ===" && \
ip route | grep default && \
echo "---" && \
ping -c 1 10.211.55.1 && \
echo "---" && \
nc -zv 10.211.55.1 9876 2>&1 && \
echo "---" && \
cat ~/.config/clippy/config.toml | grep -A 3 "\[client\]"
```

## Most Likely Issues (90% of cases)

### 1. Server bound to 127.0.0.1 (not 0.0.0.0)
**Check:** `lsof -i :9876` on macOS shows `127.0.0.1`
**Fix:** Change config `host = "0.0.0.0"`

### 2. Wrong IP address in client config
**Check:** `ip route | grep default` shows different IP
**Fix:** Update client config `server_host` to correct IP

### 3. macOS firewall blocking
**Check:** Ping works but `nc -zv` fails
**Fix:** Allow clippy in firewall settings

## Still Not Working?

Run both verification scripts and share output:

```bash
# On macOS
./scripts/verify-macos-server.sh > macos-debug.txt 2>&1

# On NixOS
./scripts/diagnose-connection.sh > nixos-debug.txt 2>&1
```

Then review the output files for specific issues.
