# Crash Recovery Protocol

> Standardized crash diagnosis and recovery guide for hermes-web-ui.
> Any AI agent (regardless of model capability) can follow this protocol to diagnose and fix crashes.

## Overview

```
┌──────────────┐    detect     ┌──────────────┐    read    ┌──────────────┐
│  Watchdog    │───(1min)────→│  Collect     │──────────→│  Classify    │
│  (systemd)   │              │  Logs & Info │           │  Error Type  │
└──────────────┘              └──────────────┘           └──────┬───────┘
                                                                │
                              ┌─────────────────────────────────┤
                              │                                 │
                         ┌────▼────┐   ┌────────┐   ┌─────────▼────────┐
                         │ Level 1 │   │ Level 2│   │    Level 3       │
                         │ Auto    │   │ Auto   │   │  Agent-Assisted  │
                         │ Restart │   │ Fix    │   │  Manual Fix      │
                         └─────────┘   └────────┘   └──────────────────┘
```

## Level Classification

### Level 1: Auto-Restart (Simple Crashes)
**Trigger**: Process exited, OOM killed, signal 9/11/15
**Action**: Watchdog auto-restarts, no agent needed

```bash
# Watchdog handles this automatically
# Check if recovered:
curl -s http://127.0.0.1:8648/health | jq .
```

### Level 2: Auto-Fix (Known Patterns)
**Trigger**: Repeated crashes after restart, known error patterns
**Action**: Agent follows fix recipes below

### Level 3: Agent-Assisted (Unknown Errors)
**Trigger**: Fix recipes don't apply, novel errors
**Action**: Agent reads crash log, applies reasoning, generates fix

---

## Step 1: Collect Information

```bash
# 1.1 Check process status
ps aux | grep hermes-web-ui | grep -v grep

# 1.2 Check systemd status (if watchdog installed)
systemctl status hermes-web-ui-watchdog --no-pager -l

# 1.3 Read crash log (most recent)
CRASH_LOG=$(ls -t ~/.hermes-web-ui/logs/crash-*.log 2>/dev/null | head -1)
if [ -n "$CRASH_LOG" ]; then
    cat "$CRASH_LOG"
else
    echo "No crash log found"
fi

# 1.4 Check system resources
free -h
df -h /home
uptime

# 1.5 Check Node.js version
node --version

# 1.6 Check if port is occupied
lsof -i :8648 2>/dev/null || ss -tlnp | grep 8648
```

## Step 2: Classify Error

Read the crash log and classify into one of these categories:

| Error Pattern | Category | Fix Level |
|---|---|---|
| `EADDRINUSE` | Port conflict | Level 2 |
| `JavaScript heap out of memory` | OOM | Level 2 |
| `MODULE_NOT_FOUND` | Missing dependency | Level 2 |
| `SyntaxError` / `TypeError` | Code error | Level 2-3 |
| `EACCES` / permission denied | Permission | Level 2 |
| `ENOSPC` | Disk full | Level 2 |
| `SIGKILL` / OOM killed | System OOM | Level 2 |
| `Cannot find module` after npm install | Corrupted node_modules | Level 2 |
| `ECONNREFUSED` to upstream | Upstream down | Level 2 |
| WebSocket connection errors | Network/proxy | Level 3 |
| Unknown / no crash log | Unknown | Level 3 |

## Step 3: Apply Fix

### Level 2 Fix Recipes

#### Recipe: EADDRINUSE (Port 8648 occupied)
```bash
# Find and kill the old process
OLD_PID=$(lsof -ti :8648 2>/dev/null)
if [ -n "$OLD_PID" ]; then
    kill "$OLD_PID"
    sleep 2
    # Force kill if still alive
    kill -9 "$OLD_PID" 2>/dev/null
fi
# Restart
systemctl restart hermes-web-ui-watchdog
```

#### Recipe: OOM (Out of Memory)
```bash
# Check what's eating memory
ps aux --sort=-%mem | head -10

# Clean up system
sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

# Restart with increased memory limit
# Edit systemd service: MemoryMax=2G
systemctl edit hermes-web-ui --force
# Add:
# [Service]
# MemoryMax=2G
# MemoryHigh=1536M
systemctl daemon-reload
systemctl restart hermes-web-ui-watchdog
```

#### Recipe: MODULE_NOT_FOUND
```bash
cd /path/to/hermes-web-ui
rm -rf node_modules package-lock.json
npm install
npm run build
systemctl restart hermes-web-ui-watchdog
```

#### Recipe: Permission Denied (EACCES)
```bash
# Fix upload directory permissions
chown -R $(whoami):$(whoami) ~/.hermes-web-ui/
chmod -R 755 ~/.hermes-web-ui/

# Fix dist permissions
chown -R $(whoami):$(whoami) /path/to/hermes-web-ui/dist/
systemctl restart hermes-web-ui-watchdog
```

#### Recipe: Disk Full (ENOSPC)
```bash
# Find large files
du -sh ~/.hermes-web-ui/upload/* 2>/dev/null | sort -rh | head -5
du -sh ~/.hermes-web-ui/logs/* 2>/dev/null | sort -rh | head -5

# Clean old logs
find ~/.hermes-web-ui/logs/ -name "crash-*.log" -mtime +7 -delete
find ~/.hermes-web-ui/logs/ -name "*.log" -size +10M -delete

# Clean old uploads
find ~/.hermes-web-ui/upload/ -mtime +30 -type f -delete

# Clean systemd journal
journalctl --vacuum-size=100M

# Verify space freed
df -h /
```

#### Recipe: Upstream Hermes Agent Down
```bash
# Check upstream
curl -s http://127.0.0.1:8642/health

# If upstream is down, restart it
# Check hermes process
ps aux | grep "hermes" | grep -v grep

# Restart hermes agent (method depends on installation)
hermes serve --port 8642 &
sleep 3

# Then restart web-ui
systemctl restart hermes-web-ui-watchdog
```

#### Recipe: Corrupted node_modules
```bash
cd /path/to/hermes-web-ui
npm cache clean --force
rm -rf node_modules
npm install
npm run build
systemctl restart hermes-web-ui-watchdog
```

### Level 3: Agent-Assisted Diagnosis

When no recipe matches, the agent should:

```bash
# 1. Read the full crash log
cat ~/.hermes-web-ui/logs/crash-*.log | tail -100

# 2. Check Node.js error details
# Look for: stack trace, error code, file path, line number

# 3. Check recent code changes
cd /path/to/hermes-web-ui
git log --oneline -5
git diff HEAD~1 --stat

# 4. Try TypeScript compilation check
npx vue-tsc --noEmit 2>&1 | head -30

# 5. Try building
npm run build 2>&1 | tail -30

# 6. Based on findings, apply targeted fix
#    - If build error: fix the TypeScript/Vue error
#    - If runtime error: check the specific file/line
#    - If memory issue: increase limits or find leak
#    - If network issue: check upstream/proxy config
```

## Step 4: Verify Recovery

```bash
# 4.1 Health check
sleep 5
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8648/health)
if [ "$HEALTH" = "200" ]; then
    echo "✅ Recovery successful"
else
    echo "❌ Still down (HTTP $HEALTH)"
    # Read latest crash log for further diagnosis
    ls -lt ~/.hermes-web-ui/logs/crash-*.log | head -3
fi

# 4.2 Check watchdog is running
systemctl is-active hermes-web-ui-watchdog

# 4.3 Quick smoke test
curl -s http://127.0.0.1:8648/health | jq .
```

## Step 5: Report

After recovery, report to the user:
1. What caused the crash (error type + root cause)
2. What fix was applied
3. Current status (healthy/down)
4. Prevention recommendation (if applicable)

---

## Crash Signal File

The watchdog writes `~/.hermes-web-ui/logs/CRASH_SIGNAL` when auto-restart fails.
Any agent can check this file to detect unattended crashes:

```bash
if [ -f ~/.hermes-web-ui/logs/CRASH_SIGNAL ]; then
    echo "⚠️ Web-UI crashed and auto-restart failed!"
    cat ~/.hermes-web-ui/logs/CRASH_SIGNAL
    # Follow this protocol to diagnose and fix
fi
```

## Directory Structure

```
~/.hermes-web-ui/
├── logs/
│   ├── crash-2026-04-26T12-00-00.log    # Crash dump
│   ├── crash-2026-04-26T12-05-00.log    # More recent
│   └── CRASH_SIGNAL                      # Auto-fix failed marker
├── upload/                               # User uploads (avatars, etc.)
└── config.json                           # App configuration
```
