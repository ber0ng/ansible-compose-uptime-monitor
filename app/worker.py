"""Background worker: checks every monitor that is due, stores the result."""
import logging
import os
import signal
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx

from db import pool

TICK_SECONDS = int(os.getenv("TICK_SECONDS", "10"))
TIMEOUT_SECONDS = float(os.getenv("CHECK_TIMEOUT_SECONDS", "10"))
HEARTBEAT = Path("/tmp/worker_heartbeat")  # touched each healthy loop; used by the container healthcheck

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("worker")
logging.getLogger("httpx").setLevel(logging.WARNING)

stop = threading.Event()

# Monitors that are enabled and whose last check is older than their interval
DUE_SQL = """
SELECT m.id, m.name, m.url
FROM monitors m
LEFT JOIN LATERAL (
    SELECT checked_at FROM checks
    WHERE monitor_id = m.id
    ORDER BY checked_at DESC
    LIMIT 1
) last ON true
WHERE m.enabled
  AND (last.checked_at IS NULL
       OR last.checked_at < now() - make_interval(secs => m.interval_seconds))
"""

INSERT_SQL = """
INSERT INTO checks (monitor_id, is_up, status_code, response_ms, error)
VALUES (%s, %s, %s, %s, %s)
"""


def check(monitor: dict) -> tuple:
    """Hit one URL and return a row for the checks table."""
    start = time.perf_counter()
    try:
        resp = httpx.get(
            monitor["url"],
            timeout=TIMEOUT_SECONDS,
            follow_redirects=True,
            headers={"User-Agent": "pulsecheck/1.0"},
        )
        ms = int((time.perf_counter() - start) * 1000)
        return (monitor["id"], resp.status_code < 400, resp.status_code, ms, None)
    except httpx.HTTPError as exc:
        ms = int((time.perf_counter() - start) * 1000)
        return (monitor["id"], False, None, ms, f"{type(exc).__name__}: {exc}"[:500])


def run_once(executor: ThreadPoolExecutor) -> None:
    with pool.connection() as conn:
        due = conn.execute(DUE_SQL).fetchall()

    if due:
        # Check URLs in parallel so one slow site doesn't hold up the rest
        results = list(executor.map(check, due))
        with pool.connection() as conn:
            with conn.cursor() as cur:
                cur.executemany(INSERT_SQL, results)
        for m, (_, up, code, ms, err) in zip(due, results):
            log.info("%s up=%s status=%s %sms%s", m["name"], up, code, ms, f" error={err}" if err else "")

    HEARTBEAT.touch()


def main() -> None:
    # Docker sends SIGTERM on stop; finish the current loop and exit cleanly
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    pool.open(wait=True, timeout=30)
    log.info("worker started (tick=%ss, timeout=%ss)", TICK_SECONDS, TIMEOUT_SECONDS)

    with ThreadPoolExecutor(max_workers=10) as executor:
        while not stop.is_set():
            try:
                run_once(executor)
            except Exception:
                log.exception("loop failed, will retry next tick")
            stop.wait(TICK_SECONDS)

    pool.close()
    log.info("worker stopped")


if __name__ == "__main__":
    main()