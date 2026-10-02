import os

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

# shared by the api and the worker 
pool = ConnectionPool(
    os.environ["DATABASE_URL"],
    open=False,
    kwargs={"row_factory": dict_row} 
)

SCHEMA = """
CREATE TABLE IF NOT EXISTS monitors (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    url TEXT NOT NULL UNIQUE,
    interval_seconds INTEGER NOT NULL DEFAULT 60,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS checks (
    id BIGSERIAL PRIMARY KEY,
    monitor_id INTEGER NOT NULL REFERENCES monitors(id) ON DELETE CASCADE,
    checked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_up BOOLEAN NOT NULL, 
    status_code INTEGER,
    response_ms INTEGER,
    error TEXT
);

CREATE INDEX IF NOT EXISTS idx_checks_monitor_time 
    ON checks (monitor_id, checked_at DESC);

"""

def init_schema() -> None:
    with pool.connection() as conn:
        conn.execute(SCHEMA)