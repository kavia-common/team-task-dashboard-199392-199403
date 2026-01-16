#!/bin/bash
set -euo pipefail

# Idempotent schema + seed for the task management app.
# - Uses CREATE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS
# - Uses INSERT ... ON CONFLICT DO NOTHING for seed data
# - Avoids destructive operations (no DROP)
#
# Connection:
#   MUST read from db_connection.txt (per container rules).
#
# Usage:
#   ./schema_setup.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ ! -f "db_connection.txt" ]; then
  echo "ERROR: db_connection.txt not found in ${SCRIPT_DIR}"
  exit 1
fi

PSQL_CMD="$(cat db_connection.txt)"

echo "Applying schema using: ${PSQL_CMD}"

run_sql () {
  local sql="$1"
  # Execute one statement at a time (per container rules).
  ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "${sql}"
}

echo "Ensuring required extensions..."
run_sql "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

echo "Creating tables..."

run_sql "CREATE TABLE IF NOT EXISTS roles (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL UNIQUE, description text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text NOT NULL UNIQUE, full_name text, password_hash text, is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS user_roles (user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, role_id uuid NOT NULL REFERENCES roles(id) ON DELETE RESTRICT, created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (user_id, role_id));"

run_sql "CREATE TABLE IF NOT EXISTS teams (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL UNIQUE, description text, created_by_user_id uuid REFERENCES users(id) ON DELETE SET NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS team_memberships (team_id uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, role_in_team text NOT NULL DEFAULT 'member', created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (team_id, user_id));"

run_sql "CREATE TABLE IF NOT EXISTS projects (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), team_id uuid NOT NULL REFERENCES teams(id) ON DELETE CASCADE, name text NOT NULL, description text, created_by_user_id uuid REFERENCES users(id) ON DELETE SET NULL, is_archived boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(team_id, name));"

run_sql "CREATE TABLE IF NOT EXISTS boards (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE, name text NOT NULL, description text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(project_id, name));"

run_sql "CREATE TABLE IF NOT EXISTS board_columns (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), board_id uuid NOT NULL REFERENCES boards(id) ON DELETE CASCADE, name text NOT NULL, position integer NOT NULL, wip_limit integer, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(board_id, name), UNIQUE(board_id, position));"

run_sql "CREATE TABLE IF NOT EXISTS tasks (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE, board_id uuid REFERENCES boards(id) ON DELETE SET NULL, column_id uuid REFERENCES board_columns(id) ON DELETE SET NULL, title text NOT NULL, description text, status text NOT NULL DEFAULT 'open', priority text NOT NULL DEFAULT 'medium', due_date date, created_by_user_id uuid REFERENCES users(id) ON DELETE SET NULL, estimate_points integer, position integer NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS task_assignments (task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, assigned_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (task_id, user_id));"

run_sql "CREATE TABLE IF NOT EXISTS task_comments (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, author_user_id uuid REFERENCES users(id) ON DELETE SET NULL, body text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS notifications (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, type text NOT NULL, title text NOT NULL, body text, entity_type text, entity_id uuid, is_read boolean NOT NULL DEFAULT false, read_at timestamptz, created_at timestamptz NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS analytics_project_rollups (project_id uuid PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE, total_tasks integer NOT NULL DEFAULT 0, open_tasks integer NOT NULL DEFAULT 0, in_progress_tasks integer NOT NULL DEFAULT 0, done_tasks integer NOT NULL DEFAULT 0, overdue_tasks integer NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now());"

run_sql "CREATE TABLE IF NOT EXISTS analytics_team_rollups (team_id uuid PRIMARY KEY REFERENCES teams(id) ON DELETE CASCADE, total_tasks integer NOT NULL DEFAULT 0, done_tasks integer NOT NULL DEFAULT 0, active_projects integer NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now());"

echo "Creating indexes..."
run_sql "CREATE INDEX IF NOT EXISTS idx_projects_team_id ON projects(team_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_boards_project_id ON boards(project_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_board_columns_board_id ON board_columns(board_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON tasks(project_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_tasks_column_id ON tasks(column_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);"
run_sql "CREATE INDEX IF NOT EXISTS idx_task_assignments_user_id ON task_assignments(user_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_task_comments_task_id ON task_comments(task_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_notifications_user_unread ON notifications(user_id, is_read) WHERE is_read = false;"

echo "Seeding minimal data (safe to re-run)..."
run_sql "INSERT INTO roles (name, description) VALUES ('admin','Full access') ON CONFLICT (name) DO NOTHING;"
run_sql "INSERT INTO roles (name, description) VALUES ('member','Standard member') ON CONFLICT (name) DO NOTHING;"

run_sql "INSERT INTO users (email, full_name, password_hash) VALUES ('admin@example.com','Admin User', NULL) ON CONFLICT (email) DO NOTHING;"
run_sql "INSERT INTO user_roles (user_id, role_id) SELECT u.id, r.id FROM users u, roles r WHERE u.email='admin@example.com' AND r.name='admin' ON CONFLICT DO NOTHING;"

run_sql "INSERT INTO teams (name, description, created_by_user_id) SELECT 'Demo Team','Default team for local dev', u.id FROM users u WHERE u.email='admin@example.com' ON CONFLICT (name) DO NOTHING;"
run_sql "INSERT INTO team_memberships (team_id, user_id, role_in_team) SELECT t.id, u.id, 'owner' FROM teams t, users u WHERE t.name='Demo Team' AND u.email='admin@example.com' ON CONFLICT DO NOTHING;"

run_sql "INSERT INTO projects (team_id, name, description, created_by_user_id) SELECT t.id, 'Demo Project','Sample project', u.id FROM teams t, users u WHERE t.name='Demo Team' AND u.email='admin@example.com' ON CONFLICT (team_id, name) DO NOTHING;"
run_sql "INSERT INTO boards (project_id, name, description) SELECT p.id, 'Main Board','Default kanban board' FROM projects p WHERE p.name='Demo Project' ON CONFLICT (project_id, name) DO NOTHING;"

run_sql "INSERT INTO board_columns (board_id, name, position) SELECT b.id, 'To Do', 1 FROM boards b WHERE b.name='Main Board' ON CONFLICT (board_id, name) DO NOTHING;"
run_sql "INSERT INTO board_columns (board_id, name, position) SELECT b.id, 'In Progress', 2 FROM boards b WHERE b.name='Main Board' ON CONFLICT (board_id, name) DO NOTHING;"
run_sql "INSERT INTO board_columns (board_id, name, position) SELECT b.id, 'Done', 3 FROM boards b WHERE b.name='Main Board' ON CONFLICT (board_id, name) DO NOTHING;"

# Demo task (kept simple; may duplicate if re-run since there's no unique constraint on title)
run_sql "INSERT INTO tasks (project_id, board_id, column_id, title, description, status, priority, position, created_by_user_id) SELECT p.id, b.id, c.id, 'Set up repo', 'Verify containers and env', 'open', 'high', 1, u.id FROM projects p, boards b, board_columns c, users u WHERE p.name='Demo Project' AND b.name='Main Board' AND c.name='To Do' AND u.email='admin@example.com' AND c.board_id=b.id LIMIT 1;"

run_sql "INSERT INTO task_assignments (task_id, user_id) SELECT t.id, u.id FROM tasks t, users u WHERE t.title='Set up repo' AND u.email='admin@example.com' ON CONFLICT DO NOTHING;"

run_sql "INSERT INTO analytics_project_rollups (project_id) SELECT p.id FROM projects p WHERE p.name='Demo Project' ON CONFLICT (project_id) DO NOTHING;"
run_sql "INSERT INTO analytics_team_rollups (team_id) SELECT t.id FROM teams t WHERE t.name='Demo Team' ON CONFLICT (team_id) DO NOTHING;"

echo "Schema + seed complete."
