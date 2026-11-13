-- CloudOps capstone schema. Runs once by the postgres image (docker-entrypoint-initdb.d) and is
-- also applied by the backend at start-up (every statement is idempotent).
CREATE TABLE IF NOT EXISTS tasks (
    id          BIGSERIAL PRIMARY KEY,
    title       VARCHAR(140) NOT NULL,
    description TEXT         NOT NULL DEFAULT '',
    status      VARCHAR(12)  NOT NULL DEFAULT 'todo'
                CHECK (status IN ('todo', 'doing', 'done')),
    priority    SMALLINT     NOT NULL DEFAULT 2 CHECK (priority BETWEEN 1 AND 3),  -- 1 high, 3 low
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tasks_status_idx  ON tasks (status, priority, created_at DESC);

-- Deployment log: the deploy script inserts a row per release so the UI can show "what is running".
CREATE TABLE IF NOT EXISTS deployments (
    id          BIGSERIAL PRIMARY KEY,
    version     VARCHAR(40)  NOT NULL,
    git_sha     VARCHAR(40)  NOT NULL,
    environment VARCHAR(20)  NOT NULL,
    hostname    VARCHAR(120) NOT NULL,
    deployed_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);
