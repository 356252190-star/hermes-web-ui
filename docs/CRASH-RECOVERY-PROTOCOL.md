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
                                                           │  Agent       │
                                                           │  Intervention│
                                                           └──────────────┘
```

### Three-Phase Recovery

| Phase | What | How |
|-------|------|-----|
| **Phase 1** | Fast Restart | Watchdog kills + restarts process (3 attempts) |
| **Phase 2** | Auto-Diagnose | Watchdog runs `crash-diagnose.sh`, checks 10 known patterns, applies fix |
| **Phase 3** | Agent Report | Writes CRASH_SIGNAL + diagnostic JSON for agent to read and fix |

**Key: Phase 2 is fully automatic** — no agent needed for known error patterns.

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

## Phase 3: Agent-Assisted Fix (When Auto-Diagnose Fails)

When CRASH_SIGNAL exists with `STATUS=AGENT_REVIEW_NEEDED`:

```bash
# 1. Read the signal
cat ~/.hermes-web-ui/logs/CRASH_SIGNAL

# 2. Run diagnosis
bash ~/.hermes-web-ui/crash-diagnose.sh

# 3. Read crash log
cat $(ls -t ~/.hermes-web-ui/logs/crash-*.log | head -1)

# 4. Check system
free -h && df -h / && uptime

# 5. Check node version
node --version

# 6. Apply fix based on ERROR_CLASS in CRASH_SIGNAL:
#    - PORT_CONFLICT → kill stale process, check port
#    - OOM → increase memory, check for leaks
#    - MISSING_MODULE → npm install + rebuild
#    - PERMISSION → chown/chmod
#    - DISK_FULL → clean disk
#    - CODE_ERROR → read stack trace, fix code, rebuild
#    - UPSTREAM_DOWN → restart hermes agent first
#    - UNKNOWN → read full crash log, analyze stack trace

# 7. After fix — clear signal and restart watchdog
rm ~/.hermes-web-ui/logs/CRASH_SIGNAL
systemctl --user restart hermes-web-ui-watchdog

# 8. Verify
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
    └── FAILURE → Phase 2: Auto-Diagnose
        │
        ├── Matched known pattern → Apply fix → Restart
        │   │
        │   ├── SUCCESS → ✅ Service restored
        │   └── FAILURE → Phase 3: Agent Report
        │
        └── No match → Phase 3: Agent Report
            │
            ▼
        Write CRASH_SIGNAL + crash log
        Agent reads, diagnoses, fixes
            │
            ▼
        ✅ Service restored
```
