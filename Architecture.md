# pulsecheck: Architecture

Diagrams of how pulsecheck is built and deployed. See [README.md](README.md) for the full configuration details.

---

## 1. Infrastructure overview

Everything that exists on AWS, and who talks to what.

```mermaid
flowchart LR
    user["🌐 Visitor<br/>browser"]
    admin["💻 Admin PC<br/>Git Bash + WSL"]

    subgraph aws["AWS · ap-southeast-2 (Sydney)"]
        s3[("S3 bucket<br/>Terraform state")]
        sched["EventBridge Scheduler<br/>stop at 11 PM Manila"]

        subgraph vpc["VPC 10.20.0.0/16"]
            igw["Internet Gateway"]
            subgraph subnet["Public subnet 10.20.1.0/24"]
                sg{{"Security group<br/>22: admin IP only<br/>80: anyone"}}
                eip["Elastic IP"]
                ec2["EC2 t3.micro<br/>Ubuntu 24.04"]
            end
        end
    end

    user -- "HTTP :80" --> igw
    admin -- "SSH :22 (Ansible)" --> igw
    admin -- "terraform apply" --> aws
    admin -. "state read/write" .-> s3
    igw --> eip --> sg --> ec2
    sched -. "ec2:StopInstances" .-> ec2
```

---

## 2. Inside the server

What runs on the EC2 instance once Ansible has finished.

```mermaid
flowchart TB
    internet["Traffic from internet"]

    subgraph host["EC2 instance · Ubuntu 24.04"]
        direction TB
        ufw{{"UFW firewall<br/>allow 22, 80 · deny rest"}}
        sshd["sshd<br/>key-only, no root"]
        f2b["fail2ban"]
        swap["2 GB swap"]

        subgraph docker["Docker Compose project: pulsecheck"]
            direction TB
            nginx["nginx<br/>:80"]
            api["api · FastAPI<br/>:8000"]
            worker["worker<br/>every 10s"]
            db[("db · Postgres 16<br/>volume: pgdata")]
        end
    end

    sites["Monitored URLs<br/>e.g. example.com"]

    internet --> ufw
    ufw -- ":22" --> sshd
    f2b -. "watches" .-> sshd
    ufw -- ":80" --> nginx
    nginx --> api
    api --> db
    worker --> db
    worker -- "HTTP checks" --> sites
```

---

## 3. Who owns what

Terraform builds the empty server. Ansible decides what runs on it.

```mermaid
flowchart LR
    subgraph tf["Terraform · terraform/aws"]
        t1["VPC, subnet, IGW, routes"]
        t2["Security group"]
        t3["EC2 + key pair"]
        t4["Elastic IP"]
        t5["Nightly stop schedule"]
    end

    subgraph an["Ansible · ansible/"]
        r1["common<br/>packages, swap"]
        r2["hardening<br/>SSH, UFW, fail2ban"]
        r3["docker<br/>Docker Engine"]
        r4["pulsecheck<br/>code, .env, stack"]
    end

    tf -- "empty Ubuntu server<br/>+ public IP" --> an
    r1 --> r2 --> r3 --> r4
```

---

## 4. Deployment flow

What happens, step by step, from nothing to a running app.

```mermaid
sequenceDiagram
    autonumber
    actor Me as Admin (PC)
    participant TF as Terraform<br/>(Git Bash)
    participant S3 as S3 state
    participant AWS as AWS
    participant AN as Ansible<br/>(WSL)
    participant VM as EC2 server

    Me->>TF: terraform apply
    TF->>S3: lock + read state
    TF->>AWS: create VPC, SG, EC2, EIP, schedule
    AWS-->>TF: public IP
    TF->>S3: save state + unlock

    Me->>AN: ansible-playbook site.yml --ask-vault-pass
    AN->>AN: read inventory, decrypt vault
    AN->>VM: SSH as ubuntu (sudo)
    AN->>VM: role common: upgrade, packages, swap
    AN->>VM: role hardening: sshd config, UFW, fail2ban
    AN->>VM: role docker: repo + Docker Engine
    AN->>VM: role pulsecheck: rsync code, write .env
    AN->>VM: docker compose up --build --wait
    AN->>VM: GET http://localhost/docs
    VM-->>AN: 200 OK
    AN-->>Me: PLAY RECAP failed=0
```

---

## 5. Request flow

A visitor opening the API docs page.

```mermaid
sequenceDiagram
    actor U as Visitor
    participant SG as AWS security group
    participant UFW as UFW
    participant N as nginx
    participant A as api
    participant D as Postgres

    U->>SG: GET http://<elastic-ip>/docs
    SG->>UFW: port 80 allowed
    UFW->>N: port 80 allowed
    N->>A: proxy to api:8000
    A->>D: query (if needed)
    D-->>A: rows
    A-->>N: response
    N-->>U: page
```

---

## 6. Worker loop

How monitoring actually happens, and how the health check knows the worker is alive.

```mermaid
flowchart TB
    start(["worker starts"]) --> wait["wait 10s"]
    wait --> due["SELECT monitors that are due"]
    due --> any{"any due?"}
    any -- yes --> check["check URLs in parallel<br/>(up to 10 at once)"]
    check --> save["INSERT results into checks"]
    save --> beat
    any -- no --> beat["touch /tmp/worker_heartbeat"]
    beat --> wait

    hc["Docker health check"] -. "is heartbeat recent?" .-> beat
```

---

## 7. Security layers

Each layer is independent, so one mistake doesn't expose the server.

```mermaid
flowchart LR
    a["Internet"] --> b["Security group<br/>(AWS)"] --> c["UFW<br/>(host firewall)"] --> d["fail2ban<br/>(brute-force bans)"] --> e["sshd<br/>key-only, no root"] --> f["Server"]
```

| Layer              | Protects against                                                 |
| ------------------ | ---------------------------------------------------------------- |
| Security group     | Anyone except you reaching SSH at all                            |
| UFW                | Anything other than 22/80 if the security group is ever loosened |
| fail2ban           | Repeated failed logins                                           |
| sshd hardening     | Password guessing and direct root access                         |
| Ansible Vault      | Secrets leaking through the Git repo                             |
| Encrypted S3 state | Infra details and IDs leaking from Terraform state               |

---

## 8. Key design decisions

| Decision                                | Why                                                                                                               |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Terraform for infra, Ansible for config | Clean boundary: each tool does what it's best at                                                                  |
| Flat Terraform (no modules)             | One environment, one server. Modules wait until there's a second consumer                                         |
| S3 native state locking                 | No DynamoDB table needed (Terraform ≥ 1.10)                                                                       |
| Ansible push mode from WSL              | Hardening runs before anything else is installed; secrets stay off the server; same model GitHub Actions will use |
| Build images on the server              | Simple for one server. A registry (e.g. ECR/GHCR) is the next step for faster, repeatable deploys                 |
| Elastic IP                              | Inventory IP stays the same across stop/start                                                                     |
| Swap on a 1 GB box                      | Image builds can spike memory                                                                                     |
| `cpu_credits = standard`                | No surprise burst charges                                                                                         |
| AWS instead of Azure                    | New Azure subscription had 0 quota for the B-series family                                                        |

---

## 9. Next: CI/CD (planned)

```mermaid
flowchart LR
    push["git push main"] --> gha["GitHub Actions"]
    gha -- "OIDC (no stored keys)" --> iam["AWS IAM role"]
    iam --> sgopen["add runner IP to SG"]
    sgopen --> play["ansible-playbook"]
    play --> vm["EC2 server"]
    play --> sgclose["remove runner IP"]
```
