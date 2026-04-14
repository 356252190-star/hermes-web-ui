# Official Hermes Dashboard API Integration

Branch: `feat/official-api`

## Overview
Integrate with the official Hermes REST API (`hermes dashboard` on `127.0.0.1:9119`) to replace or supplement CLI-based data fetching.

Reference: https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard

## Priority

### High
1. **Config management page** — `GET/PUT /api/config`, `GET /api/config/schema`
   - New settings page with form-based config editor
   - All config fields auto-discovered from schema
   - Save, reset to defaults, export/import
2. **API Key management** — `GET/PUT/DELETE /api/env`
   - View, set, delete API keys
   - Grouped by category (LLM, Tools, Messaging)
   - Redacted value display
3. **Session search** — `GET /api/sessions/search?q=...`
   - Full-text search across all message content
   - Highlighted snippets

### Medium
4. **Analytics** — `GET /api/analytics/usage?days=30`
   - Use official API data instead of computing from session list
   - More accurate cost/cache stats
5. **Cron job management** — Full CRUD
   - Create, pause/resume, trigger, delete scheduled jobs
   - Job list with status, schedule, run history
6. **Skills toggle** — `PUT /api/skills/toggle`
   - Enable/disable skills directly from UI
7. **Status enhancement** — `GET /api/status`
   - Platform connection states
   - Active session count

### Low
8. **Toolsets** — `GET /api/tools/toolsets`
   - Display available toolsets with status

## Architecture
- BFF (Koa) proxies requests to official API at `127.0.0.1:9119`
- Fallback to CLI when official API is not available
- User can configure official dashboard address in settings
- CORS: official API restricts to localhost, our BFF handles this

## API Endpoints to Integrate
- `GET /api/status`
- `GET /api/sessions`, `GET /api/sessions/{id}`, `GET /api/sessions/{id}/messages`
- `GET /api/sessions/search?q=...`
- `DELETE /api/sessions/{id}`
- `GET /api/config`, `GET /api/config/defaults`, `GET /api/config/schema`, `PUT /api/config`
- `GET /api/env`, `PUT /api/env`, `DELETE /api/env`
- `GET /api/logs`
- `GET /api/analytics/usage?days=N`
- `GET /api/cron/jobs`, `POST /api/cron/jobs`, `POST/DELETE /api/cron/jobs/{id}/*`
- `GET /api/skills`, `PUT /api/skills/toggle`
- `GET /api/tools/toolsets`
