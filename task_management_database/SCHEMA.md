# Task Management Database Schema (PostgreSQL)

This container runs PostgreSQL and provides the application schema used by the FastAPI backend.

Connection info is stored in `db_connection.txt` (example: `psql postgresql://appuser:dbuser123@localhost:5000/myapp`).

## Design goals

- ORM-friendly naming/types:
  - UUID primary keys (`uuid` + `gen_random_uuid()` from `pgcrypto`)
  - `created_at` / `updated_at` timestamps (`timestamptz`)
  - Join tables for many-to-many relationships
- Safe/idempotent local initialization:
  - `CREATE TABLE IF NOT EXISTS`
  - `CREATE INDEX IF NOT EXISTS`
  - `INSERT ... ON CONFLICT DO NOTHING`
- No destructive operations on startup (no `DROP`).

## Tables

### RBAC
- `roles`
  - `id` (uuid, PK)
  - `name` (text, unique)
- `users`
  - `id` (uuid, PK)
  - `email` (text, unique)
  - `password_hash` (text, nullable)
  - `is_active` (boolean)
- `user_roles` (M:N)
  - PK `(user_id, role_id)`
  - FK to `users`, `roles`

### Teams
- `teams`
  - `id` (uuid, PK)
  - `name` (text, unique)
  - `created_by_user_id` → `users(id)` (SET NULL)
- `team_memberships` (M:N)
  - PK `(team_id, user_id)`
  - `role_in_team` (text)

### Projects / Boards
- `projects`
  - `id` (uuid, PK)
  - `team_id` → `teams(id)` (CASCADE)
  - `name` (unique within team via `UNIQUE(team_id, name)`)
- `boards`
  - `id` (uuid, PK)
  - `project_id` → `projects(id)` (CASCADE)
  - `name` (unique within project via `UNIQUE(project_id, name)`)
- `board_columns`
  - `id` (uuid, PK)
  - `board_id` → `boards(id)` (CASCADE)
  - `name` unique per board
  - `position` unique per board

### Tasks
- `tasks`
  - `id` (uuid, PK)
  - `project_id` → `projects(id)` (CASCADE)
  - `board_id` → `boards(id)` (SET NULL)
  - `column_id` → `board_columns(id)` (SET NULL)
  - `status` (text; e.g., open/in_progress/done)
  - `priority` (text; e.g., low/medium/high)
- `task_assignments` (M:N)
  - PK `(task_id, user_id)`
- `task_comments`
  - `id` (uuid, PK)
  - `task_id` → `tasks(id)` (CASCADE)
  - `author_user_id` → `users(id)` (SET NULL)

### Notifications
- `notifications`
  - `id` (uuid, PK)
  - `user_id` → `users(id)` (CASCADE)
  - `is_read` (boolean) + partial index for unread per user

### Analytics rollups
- `analytics_project_rollups`
  - PK `project_id` → `projects(id)` (CASCADE)
  - aggregated counters
- `analytics_team_rollups`
  - PK `team_id` → `teams(id)` (CASCADE)

## Setup / seed

Run:

```bash
cd task_management_database
chmod +x schema_setup.sh
./schema_setup.sh
```

The script is safe to re-run. It will:
- create missing tables/indexes
- insert minimal dev data:
  - roles: `admin`, `member`
  - user: `admin@example.com`
  - team: `Demo Team`
  - project: `Demo Project`
  - board: `Main Board` + columns
  - a demo task
