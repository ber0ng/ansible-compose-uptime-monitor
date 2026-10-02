# ansible-compose-uptime-monitor# pulsecheck

A small self-hosted uptime monitor (think a mini UptimeRobot / Uptime Kuma), used as the
workload for a Terraform + Ansible + Docker Compose deployment project.

```
             :8080
  you ──▶  nginx ──▶ api (FastAPI) ──▶ postgres
                                         ▲
                     worker (Python) ────┘
                       └─▶ checks your URLs every interval
```

## Roadmap

1. **Local stack** with Docker Compose <- you are here
2. Terraform: provision Linux VMs, container registry, networking
3. Ansible: harden VMs, install Docker, deploy this stack
4. GitHub Actions: build/push image, lint, run playbooks

## Run locally

```bash
cp .env.example .env        # then edit the password
docker compose up -d --build
docker compose ps           # wait until everything is healthy
docker compose logs -f worker
```

Open http://localhost:8080/docs to use the API in the browser.

## Endpoints

| Method | Path                  | What it does                    |
| ------ | --------------------- | ------------------------------- |
| GET    | /healthz              | API + DB check                  |
| GET    | /monitors             | All monitors with latest status |
| POST   | /monitors             | Add a URL to monitor            |
| GET    | /monitors/{id}        | One monitor + 24h uptime %      |
| GET    | /monitors/{id}/checks | Recent check history            |
| DELETE | /monitors/{id}        | Stop monitoring a URL           |

## Tear down

```bash
docker compose down        # keep data
docker compose down -v     # also delete the Postgres volume
```

## Known limitations (on purpose, for now)

- Checks run from a single location.
- No alerting yet (Slack/email is a stretch goal).
- Check history is never pruned.
- Any URL can be added, including internal addresses. Fine for a personal tool,
  but a real service would need SSRF protection.
