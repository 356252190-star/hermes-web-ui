# Crash Recovery Protocol

Standardized crash diagnosis and recovery guide for `hermes-web-ui`. Any AI agent can follow this protocol to diagnose and fix crashes.

**Platform Support:** Linux (systemd) + macOS (launchd)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Recovery Layers                         │
├─────────────────────────────────────────────────────────────┤
│  Level 1: watchdog (auto-restart, 3 retries)                │
│           ↓ fails                                            │
│  Level 2: Known Patterns (deterministic fix recipes)        │
│           ↓ no match                                         │
│  Level 3: Agent-Assisted (structured investigation)         │
└─────────────────────────────────────────────────────────────┘
```

---

## Level 1: Auto-Restart (watchdog)

The watchdog health-checks every 30s and auto-restarts on failure.

- **Max retries:** 3 consecutive failures
- **Crash logs:** `~/.hermes-web-ui/crash-logs/`
- **Signal file:** `~/.hermes-web-ui/CRASH_SIGNAL` (created when auto-recovery fails)

When `CRASH_SIGNAL` exists, any AI agent should intervene.

### Service Management

| Platform | Status | Logs | Start/Stop |
|----------|--------|------|------------|
| Linux | `systemctl status hermes-web-ui-watchdog` | `journalctl -u hermes-web-ui-watchdog -f` | `systemctl start/stop hermes-web-ui-watchdog` |
| macOS | `launchctl list \| grep hermes` | `cat ~/.hermes-web-ui/watchdog-stdout.log` | `launchctl start/stop com.hermes-web-ui.watchdog` |

---

## Level 2: Known Error Patterns

### 2.1 EADDRINUSE (Port Conflict)

**Symptom:** `Error: listen EADDRINUSE :::8648`

**Fix (Linux):**
```bash
lsof -i :8648 | grep LISTEN
kill -9 <PID>
systemctl restart hermes-web-ui
```

**Fix (macOS):**
```bash
lsof -i :8648 | grep LISTEN
kill -9 <PID>
```

**Root cause:** Previous instance didn't exit cleanly.

---

### 2.2 OOM (Out of Memory)

**Symptom:** Exit code 137, or `FATAL ERROR: CALL_AND_RETRY_LAST Allocation failed`

**Diagnosis:**
```bash
# Linux
free -h
cat /proc/$(pgrep -f hermes-web-ui)/status | grep VmRSS

# macOS
vm_stat
ps -eo pid,rss,command | grep hermes-web-ui
```

**Fix:**
```bash
# Option A: Increase Node.js heap
export NODE_OPTIONS="--max-old-space-size=512"

# Option B: Add swap (Linux only)
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

---

### 2.3 MODULE_NOT_FOUND (Missing Dependency)

**Symptom:** `Error: Cannot find module 'xxx'`

**Fix:**
```bash
cd /path/to/hermes-web-ui-src
npm install

# If node_modules corrupted
rm -rf node_modules package-lock.json
npm install
```

---

### 2.4 EACCES (Permission Denied)

**Symptom:** `EACCES: permission denied, open '/path/to/file'`

**Fix:**
```bash
chown -R $(whoami):$(id -gn) ~/.hermes-web-ui/
chmod -R 755 ~/.hermes-web-ui/
```

---

### 2.5 ENOSPC (Disk Full)

**Symptom:** `ENOSPC: no space left on device`

**Fix:**
```bash
df -h
du -sh ~/.hermes-web-ui/* | sort -rh | head -10
find ~/.hermes-web-ui/crash-logs -mtime +7 -delete
```

---

### 2.6 Upstream Hermes Agent Down

**Symptom:** Health check returns 502/503, or `ECONNREFUSED` to gateway

**Diagnosis:**
```bash
curl -s http://127.0.0.1:8642/health
pgrep -af hermes
```

**Fix:**
```bash
# Linux
systemctl restart hermes-agent

# Or via OpenClaw
cd /home/o2/.openclaw
openclaw restart
```

---

### 2.7 Corrupted node_modules

**Symptom:** Random module errors, `TypeError: xxx is not a function`

**Fix:**
```bash
cd /path/to/hermes-web-ui-src
rm -rf node_modules package-lock.json
npm install
npm run build
```

---

### 2.8 Gateway Connection Timeout

**Symptom:** `ETIMEDOUT`, requests hang

**Fix:**
```bash
# Increase timeout in .env
GATEWAY_TIMEOUT=60000
```

---

## Level 3: Agent-Assisted (Unknown Errors)

### Step 1: Read Crash Context
```bash
cat ~/.hermes-web-ui/CRASH_SIGNAL
ls -t ~/.hermes-web-ui/crash-logs/*.log | head -1 | xargs cat

# Linux
journalctl -u hermes-web-ui --since "10 minutes ago" --no-pager
# macOS
tail -100 ~/.hermes-web-ui/watchdog-stdout.log
```

### Step 2: Classify Error
- Node.js error? (stack trace shows node_modules)
- System error? (EACCES, ENOSPC, OOM)
- Network error? (ECONNREFUSED, ETIMEDOUT)

### Step 3: Reason About Root Cause
1. Check recent changes: `git log --oneline -5`
2. Check config: `cat ~/.hermes-web-ui/.env`
3. Check disk/memory
4. Check port conflicts: `lsof -i :8648`

### Step 4: Apply Fix → Verify → Document

---

## Quick Reference

| Error | Exit Code | Auto-fix? | Command |
|-------|-----------|-----------|---------|
| EADDRINUSE | 1 | Yes | `lsof -i :8648 \| awk 'NR>1{print $2}' \| xargs kill` |
| OOM | 137 | Partial | Add swap / increase heap |
| MODULE_NOT_FOUND | 1 | Yes | `npm install` |
| EACCES | 1 | Yes | `chown -R $(whoami):$(id -gn) ~/.hermes-web-ui` |
| ENOSPC | 1 | No | Clean disk manually |
| Gateway down | - | No | Restart hermes-agent |

---

## File Locations

| File | Path |
|------|------|
| Crash signal | `~/.hermes-web-ui/CRASH_SIGNAL` |
| Crash logs | `~/.hermes-web-ui/crash-logs/` |
| Watchdog log | `~/.hermes-web-ui/watchdog.log` |
| Service (Linux) | `/etc/systemd/system/hermes-web-ui-watchdog.service` |
| Service (macOS) | `~/Library/LaunchAgents/com.hermes-web-ui.watchdog.plist` |
