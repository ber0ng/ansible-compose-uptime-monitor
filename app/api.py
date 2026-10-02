from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import FastAPI, HTTPException, Query
from psycopg.errors import UniqueViolation
from pydantic import BaseModel, Field, HttpUrl

from db import init_schema, pool

@asynccontextmanager
async def lifespan(app: FastAPI):
    pool.open(wait=True, timeout=30)
    init_schema() # the api owns this schema; worker starts after it 
    yield
    pool.close()

app = FastAPI(title="pulsecheck", lifespan=lifespan)

# req/response models

class MonitorIn(BaseModel):
    name: str = Field(min_length=1, max_length=100, examples=["Google"])
    url: HttpUrl = Field(examples=["https://www.google.com"])
    interval_seconds: int = Field(default=60, ge=30, le=3600)

class Monitor(BaseModel):
    id: int
    name: str
    url: HttpUrl
    interval_seconds: int
    is_up: bool | None
    status_code: int | None
    response_ms: int | None
    last_checked: datetime | None

class MonitorDetail(Monitor):
    uptime_24h: float | None 

class Check(BaseModel):
    checked_at: datetime
    is_up: bool
    status_code: int | None
    response_ms: int | None
    error: str | None

# each monitor joined with its most recent check, if any
MONITOR_SELECT = """
SELECT m.id, m.name, m.url, m.interval_seconds,
       c.is_up, c.status_code, c.response_ms, c.checked_at AS last_checked
FROM monitors m
LEFT JOIN LATERAL (
    SELECT is_up, status_code, response_ms, checked_at
    FROM checks c
    WHERE c.monitor_id = m.id
    ORDER BY checked_at DESC
    LIMIT 1
) c ON TRUE
"""

# endpoints
@app.get("/healthz")
def healthz():
    with pool.connection() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}

@app.get("/monitors", response_model=list[Monitor])
def list_monitors():
    with pool.connection() as conn:
        return conn.execute(MONITOR_SELECT + " ORDER BY m.id").fetchall()

@app.post("/monitors", response_model=Monitor, status_code=201)
def create_monitor(monitor: MonitorIn):
    try:
        with pool.connection() as conn:
            new_id = conn.execute(
                "INSERT INTO MONITORS (name, url, interval_seconds) VALUES (%s, %s, %s) RETURNING id",
                (monitor.name, str(monitor.url), monitor.interval_seconds)
            ).fetchone()["id"]
            return conn.execute(MONITOR_SELECT + " WHERE m.id = %s", (new_id,)).fetchone()
    except UniqueViolation:
        raise HTTPException(status_code=409, detail="That url is already monitored")

@app.get("/monitors/{monitor_id}", response_model=MonitorDetail)
def get_monitor(monitor_id: int):
    with pool.connection() as conn:
        row = conn.execute(MONITOR_SELECT + " WHERE m.id = %s", (monitor_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Monitor not found")
        uptime = conn.execute(
            """
            SELECT round(100.0 * avg(is_up::int), 2) AS pct
            FROM checks
            WHERE monitor_id = %s AND checked_at > now() - interval '24 hours'
            """,
            (monitor_id,),
        ).fetchone()["pct"]
    return {**row, "uptime_24h": float(uptime) if uptime is not None else None}

@app.get("/monitors/{monitor_id}/checks", response_model=list[Check])
def list_checks(monitor_id: int, limit: int = Query(50, ge=1, le=500)):
    with pool.connection() as conn:
        return conn.execute(
            """
            SELECT checked_at, is_up, status_code, response_ms, error
            FROM checks
            WHERE monitor_id = %s
            ORDER BY checked_at DESC
            LIMIT %s
            """,
            (monitor_id, limit)
        ).fetchall()

@app.delete("/monitors/{monitor_id}", status_code=204)
def delete_monitor(monitor_id: int):
    with pool.connection() as conn:
        result = conn.execute("DELETE FROM monitors WHERE id = %s", (monitor_id,))
        if result.rowcount == 0:
            raise HTTPException(status_code=404, detail="Monitor not found")