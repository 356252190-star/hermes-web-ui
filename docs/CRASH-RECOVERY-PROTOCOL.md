# Crash Recovery Protocol

> Standardized crash diagnosis and recovery guide for hermes-web-ui.
> Any AI agent (regardless of model capability) can follow this protocol to diagnose and fix crashes.

## Overview

```
┌──────────────┐    detect     ┌──────────────┐   Phase 1   ┌──────────────┐
│  Watchdog    │───(30s)──────→│  Fast        │───(3x)────→│  Auto        │
│  (systemd)   │               │  Restart     │             │  Diagnose    │
└──────────────┘               └──────────────┘             └──────┬───────┘
                                                                    │
                                                           ┌──────▼───────┐
                                                           │  Phase 3     │
                                                           │  Agent Auto  │
                                                           │  Repair      │
                                                           └──────┬───────┘
                                                                    │
                                                           ┌──────▼───────┐
                                                           │  Phase 4     │
                                                           │  Manual      │
                                                           │  Intervention│
                                                           └──────────────┘
```

### Four-Phase Recovery

| Phase | What | How |
|-------|------|-----|
| **Phase 1** | Fast Restart | Watchdog kills + restarts process (3 attempts) |
| **Phase 2** | Auto-Diagnose | Watchdog runs `crash-diagnose.sh`, checks 8 known patterns, applies fix |
| **Phase 3** | Agent Auto-Repair | Watchdog calls `hermes chat -q` with diagnostic context → agent follows this protocol to fix |
| **Phase 4** | Manual Report | Writes CRASH_SIGNAL + diagnostic JSON for human intervention |

**Key: Phase 2 & 3 are fully automatic** — no human needed for known error patterns AND unknown errors (via agent).

## Error Classification

| Error Pattern | Class | Phase 2 Fix |
|---|---|---|
| `EADDRINUSE` | PORT_CONFLICT | Kill stale process on port |
| `JavaScript heap out of memory` | OOM | Clean memory + kill heavy processes |
| `MODULE_NOT_FOUND` | MISSING_MODULE | `npm install` + rebuild |
| `EACCES` / permission denied | PERMISSION | Fix file ownership/permissions |
| `ENOSPC` | DISK_FULL | Clean logs, uploads, journal |
| `SyntaxError` / `TypeError` | CODE_ERROR | Rebuild from source |
| `ECONNREFUSED` to upstream | UPSTREAM_DOWN | Restart + check upstream |
| Corrupted node_modules | CORRUPTED_DEPS | Full reinstall |
| Unknown / no pattern | UNKNOWN | Agent review needed |

## Quick Reference

### Check if web-ui is down
```bash
# Health check
curl -s http://127.0.0.1:8648/health | jq .

# Process check
pgrep -f "hermes-web-ui.*dist/server"

# CRASH_SIGNAL check
cat ~/.hermes-web-ui/logs/CRASH_SIGNAL 2>/dev/null
```

### Run manual diagnosis
```bash
# Human-readable output
bash ~/.hermes-web-ui/crash-diagnose.sh

# JSON output (for agent consumption)
bash ~/.hermes-web-ui/crash-diagnose.sh --json
```

### Maintenance mode (during updates)
```bash
# Enable — watchdog pauses
touch ~/.hermes-web-ui/.maintenance

# Disable — watchdog resumes
rm ~/.hermes-web-ui/.maintenance
```

## Phase 3: Agent Auto-Repair (Fully Automatic)

When Phase 1 & 2 fail, watchdog automatically triggers the hermes agent to diagnose and fix.

### How it works

1. Watchdog detects hermes-agent is running (checks CLI + health endpoint)
2. If agent is down → attempts to start it first (`systemctl --user start hermes-gateway`)
3. Calls `hermes chat --yolo -q "<repair prompt>"` with:
   - Error classification
   - Crash log content
   - Structured diagnosis output
   - Instructions to follow this protocol
4. Agent reads the crash report, diagnoses, applies fix, verifies health
5. Watchdog verifies health endpoint responds 200

### Agent Repair Prompt Template

```
## Web-UI Crash Auto-Repair Task

The hermes-web-ui service has crashed and automated recovery (Phase 1 & 2) failed.
You are being called to diagnose and fix the issue automatically.

### Error Classification: {ERROR_CLASS}

### Diagnosis Output:
{JSON from crash-diagnose.sh --json}

### Crash Log:
{Last 100 lines of crash log}

### Instructions:
1. Read the crash recovery protocol: docs/CRASH-RECOVERY-PROTOCOL.md
2. Read the latest crash log
3. Check system resources
4. Based on error class, apply the appropriate fix
5. After fixing, verify health endpoint
6. If fixed, clean up CRASH_SIGNAL
7. Report what you did
```

### Configuration

```bash
# Agent timeout (default: 300s = 5min)
AGENT_TIMEOUT=300 ./watchdog.sh

# Max Phase 3 attempts per day (default: 2)
# Set in watchdog.sh: PHASE3_MAX_ATTEMPTS=2
```

### Fallback

If hermes-agent is also down and can't be started:
- Watchdog logs the failure
- Falls through to Phase 4 (manual report)

## Phase 4: Manual Intervention (Last Resort)

When ALL automatic phases fail (Phase 1 + 2 + 3), watchdog writes a CRASH_SIGNAL file:

```bash
# 1. Read the signal
cat ~/.hermes-web-ui/logs/CRASH_SIGNAL

# 2. Run diagnosis
bash ~/.hermes-web-ui/crash-diagnose.sh

# 3. Read crash log
cat $(ls -t ~/.hermes-web-ui/logs/crash-*.log | head -1)

# 4. Check system
free -h && df -h / && uptime

# 5. Apply fix based on ERROR_CLASS:
#    - PORT_CONFLICT → kill stale process
#    - OOM → increase memory, check for leaks
#    - MISSING_MODULE → npm install + rebuild
#    - PERMISSION → chown/chmod
#    - DISK_FULL → clean disk
#    - CODE_ERROR → read stack trace, fix code, rebuild
#    - UPSTREAM_DOWN → restart hermes agent first
#    - UNKNOWN → read full crash log, analyze stack trace

# 6. After fix — clear signal and restart watchdog
rm ~/.hermes-web-ui/logs/CRASH_SIGNAL
systemctl --user restart hermes-web-ui-watchdog

# 7. Verify
curl -s http://127.0.0.1:8648/health | jq .
```

## Safety Features

### Global Circuit Breaker
- If **30 failures** accumulate in one day, watchdog stops permanently
- Requires manual intervention to restart
- Prevents infinite restart loops on persistent issues

### Maintenance Mode
- Touch `.maintenance` file before any manual update
- Watchdog pauses all checks during maintenance
- Prevents watchdog from fighting with intentional restarts

### Port Release Safety
- Before restart, watchdog waits up to 10s for port to be free
- Prevents new process from failing due to port conflict

### Agent Repair Timeout
- Phase 3 agent call has a configurable timeout (default 300s)
- Prevents agent from hanging indefinitely
- Watchdog kills the call if it exceeds timeout

### Dry Run Mode
- `--dry-run` flag: detect-only, no restart actions
- Useful for testing watchdog logic without affecting the service

## Directory Structure

```
~/.hermes-web-ui/
├── logs/
│   ├── crash-2026-04-26T12-00-00.log    # Crash dump (auto-generated)
│   └── CRASH_SIGNAL                       # Auto-fix failed marker
├── watchdog-state                         # Persistent failure counter
├── crash-diagnose.sh                      # Standalone diagnosis tool
├── watchdog.sh                            # Watchdog script
├── .maintenance                           # Maintenance mode flag
├── upload/                                # User uploads (avatars, etc.)
└── config.json                            # App configuration
```

## Recovery Flow Diagram

```
Web-UI crashes
    │
    ▼
Phase 1: Fast Restart (3 attempts)
    │
    ├── SUCCESS → ✅ Service restored
    │
    └── FAILURE → Phase 2: Auto-Diagnose (3 rounds)
        │
        ├── Matched known pattern → Apply fix → Restart
        │   │
        │   ├── SUCCESS → ✅ Service restored
        │   │
        │   └── FAILURE → Phase 3: Agent Auto-Repair
        │
        └── No match → Phase 3: Agent Auto-Repair
            │
            ├── Hermes agent available?
            │   ├── YES → hermes chat -q "diagnose and fix"
            │   │   │
            │   │   ├── Agent fixes it → ✅ Service restored
            │   │   │
            │   │   └── Agent fails → Phase 4: Manual Report
            │   │
            │   └── NO → Try start agent first
            │       │
            │       ├── Agent starts → Retry repair
            │       │
            │       └── Can't start → Phase 4: Manual Report
            │
            ▼
        Write CRASH_SIGNAL + diagnostic report
        Human reads, diagnoses, fixes
            │
            ▼
        ✅ Service restored
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Normal operation / success |
| 1 | Configuration error |
| 130 | SIGINT (Ctrl+C) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 8648 | Web-UI port |
| `CHECK_INTERVAL` | 30 | Seconds between health checks |
| `MAX_RETRIES` | 3 | Phase 1 restart attempts |
| `LOG_DIR` | ~/.hermes-web-ui/logs | Log directory |
| `STATE_FILE` | ~/.hermes-web-ui/watchdog-state | Persistent state |
| `RESTART_CMD` | (auto-detect) | Custom restart command |
| `AGENT_TIMEOUT` | 300 | Phase 3 agent call timeout (seconds) |
