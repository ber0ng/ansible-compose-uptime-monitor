# pulsecheck: Deployment Guide

How pulsecheck gets from this repo onto a running server on AWS, what every piece of configuration does, and how to operate it day to day.

---

## 1. Overview

pulsecheck is a self-hosted uptime monitor. You give it URLs, and a background worker checks them on a schedule and stores the results.

The deployment has three layers, each owned by a different tool:

| Layer              | Tool           | What it does                                                     |
| ------------------ | -------------- | ---------------------------------------------------------------- |
| The app            | Docker Compose | Defines the 4 containers and how they run together               |
| The infrastructure | Terraform      | Creates the network, firewall and server on AWS                  |
| The configuration  | Ansible        | Sets up the server, secures it, installs Docker, deploys the app |

The boundary is deliberate: **Terraform builds the empty server, Ansible decides what runs on it.** Terraform never installs software, and Ansible never creates cloud resources.

```
 Your PC
 ├── Git Bash   ── terraform apply ──────────►  AWS (ap-southeast-2)
 │                                              ├── VPC + subnet + internet gateway
 │                                              ├── Security group (firewall)
 │                                              ├── EC2 instance (Ubuntu 24.04)
 │                                              └── Elastic IP
 │
 └── WSL Ubuntu ── ansible-playbook ── SSH ──►  The EC2 instance
                   (control node)               ├── packages, swap
                                                ├── SSH hardening, UFW, fail2ban
                                                ├── Docker Engine
                                                └── pulsecheck stack
```

---

## 2. The application

Four containers, defined in `compose.yaml`:

| Container | Image              | Job                                                            |
| --------- | ------------------ | -------------------------------------------------------------- |
| `nginx`   | nginx:1.27-alpine  | Front door. Receives traffic on port 80, forwards to the API   |
| `api`     | built from repo    | FastAPI app for adding/listing monitors. Docs at `/docs`       |
| `worker`  | built from repo    | Every 10s, checks monitors that are due and saves results      |
| `db`      | postgres:16-alpine | Stores monitors and check history (volume `pulsecheck_pgdata`) |

**Request flow:**

```
Browser → Elastic IP:80 → AWS security group → UFW on the server → nginx → api → Postgres
```

**Worker flow (runs on its own):**

```
worker → read due monitors from Postgres → HTTP check each URL → write results to Postgres → touch /tmp/worker_heartbeat
```

**Health checks:** the `worker` container is healthy as long as `/tmp/worker_heartbeat` keeps getting updated. The file path in `worker.py` and in the health check must match.

---

## 3. Repo layout

```
ansible-compose-uptime-monitor/
├── api/, worker files, nginx/      ← the app
├── compose.yaml                    ← local stack (nginx on 8080)
├── .env.example                    ← template for local .env
├── terraform/
│   ├── azure/                      ← original Azure version (blocked by quota)
│   └── aws/                        ← the one in use
└── ansible/
    ├── inventory/hosts.ini
    ├── group_vars/pulsecheck/
    │   ├── vars.yml
    │   └── vault.yml               ← encrypted
    ├── roles/
    │   ├── common/
    │   ├── hardening/
    │   ├── docker/
    │   └── pulsecheck/
    └── site.yml
```

**Never committed** (gitignored): `terraform.tfvars`, `backend.hcl`, `.terraform/`, `.env`.
**Safe to commit:** `vault.yml`, because it's encrypted.

---

## 4. Terraform (AWS infrastructure)

Folder: `terraform/aws/`. Run from **Git Bash**.

### 4.1 Files

| File               | Contents                                                                              |
| ------------------ | ------------------------------------------------------------------------------------- |
| `versions.tf`      | Terraform ≥ 1.10, AWS provider ~> 6.0, S3 backend, default tags on every resource     |
| `variables.tf`     | Inputs: project name, region, instance type, your IP, SSH key path, shutdown schedule |
| `main.tf`          | Network, security group, key pair, EC2 instance, Elastic IP                           |
| `schedule.tf`      | Nightly auto-stop (EventBridge Scheduler + IAM role)                                  |
| `outputs.tf`       | Public IP, ready-made SSH command, AMI name                                           |
| `terraform.tfvars` | Your values (gitignored)                                                              |
| `backend.hcl`      | State bucket settings (gitignored)                                                    |

### 4.2 Resources created

| Resource                        | Name                                    | Why                                                          |
| ------------------------------- | --------------------------------------- | ------------------------------------------------------------ |
| `aws_vpc`                       | vpc-pulsecheck (10.20.0.0/16)           | Private network for the server                               |
| `aws_internet_gateway`          | igw-pulsecheck                          | The VPC's door to the internet                               |
| `aws_subnet`                    | subnet-pulsecheck-public (10.20.1.0/24) | Where the server lives                                       |
| `aws_route_table` + association | rt-pulsecheck-public                    | Sends internet-bound traffic (0.0.0.0/0) through the gateway |
| `aws_security_group`            | sg-pulsecheck                           | Cloud firewall                                               |
| ingress rule                    | SSH (22)                                | **From your IP only** (`my_ip`)                              |
| ingress rule                    | HTTP (80)                               | From anywhere                                                |
| egress rule                     | all                                     | Server can reach the internet (apt, Docker Hub, URL checks)  |
| `aws_key_pair`                  | pulsecheck-deployer                     | Your public SSH key, installed on the server                 |
| `aws_instance`                  | ec2-pulsecheck-01                       | The Ubuntu 24.04 server                                      |
| `aws_eip`                       | eip-pulsecheck                          | Fixed public IP that survives stop/start                     |
| `aws_iam_role` + policy         | pulsecheck-scheduler                    | Lets the scheduler stop _only this_ instance                 |
| `aws_scheduler_schedule`        | pulsecheck-nightly-stop                 | Stops the server at 11 PM Asia/Manila                        |

### 4.3 Notable settings on the EC2 instance

| Setting         | Value                                                   | Why                                                    |
| --------------- | ------------------------------------------------------- | ------------------------------------------------------ |
| AMI             | Latest Canonical Ubuntu 24.04 (looked up automatically) | No hardcoded image IDs                                 |
| `instance_type` | t3.micro                                                | Small/cheap; 1 GB RAM (swap added by Ansible)          |
| `cpu_credits`   | standard                                                | t3 defaults to "unlimited" burst, which can bill extra |
| `http_tokens`   | required                                                | Enforces IMDSv2 (more secure instance metadata)        |
| Root disk       | 20 GB gp3, encrypted                                    |                                                        |

### 4.4 Variables (`terraform.tfvars`)

| Variable              | Example                 | Notes                                                                                              |
| --------------------- | ----------------------- | -------------------------------------------------------------------------------------------------- |
| `my_ip`               | `203.0.113.10/32`       | Get it with `curl -s https://checkip.amazonaws.com`, add `/32`. Update if your ISP changes your IP |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | Public half of the key Ansible uses                                                                |
| `instance_type`       | `t3.micro`              | Optional override, e.g. `t3.small`                                                                 |
| `region`              | `ap-southeast-2`        | Default in `variables.tf`                                                                          |
| `shutdown_cron`       | `cron(0 23 * * ? *)`    | Default in `variables.tf`                                                                          |

### 4.5 Remote state

Terraform's record of what it built lives in S3, not on your PC.

- Bucket: `pulsecheck-tfstate-<account-id>` (versioning on, encrypted, public access blocked by default)
- Key: `pulsecheck/terraform.tfstate`
- Locking: `use_lockfile = true` (S3 native locking; no DynamoDB table needed)

The bucket was created once by hand with the AWS CLI, because Terraform can't store its state in a bucket it hasn't created yet.

### 4.6 Commands

```bash
cd terraform/aws
terraform init -backend-config=backend.hcl   # first time / after backend changes
terraform plan                               # preview
terraform apply                              # create/update
terraform output                             # show IP and SSH command
terraform destroy                            # delete everything
```

---

## 5. Ansible (server configuration + deploy)

Folder: `ansible/`. Run from **WSL Ubuntu**, in the **repo root**.

### 5.1 Concepts in one table

| Concept        | In this project                   | What it means                                                      |
| -------------- | --------------------------------- | ------------------------------------------------------------------ |
| Control node   | WSL Ubuntu                        | Where Ansible runs. Nothing is installed on the server (agentless) |
| Managed node   | The EC2 instance                  | The server being configured, reached over SSH                      |
| Inventory      | `inventory/hosts.ini`             | Address book of servers and how to log in                          |
| Playbook       | `site.yml`                        | Main script: which hosts, which roles, in what order               |
| Role           | `roles/<name>/`                   | A group of related tasks for one job                               |
| Task           | each `- name:` block              | One step, using one module                                         |
| Module         | `apt`, `copy`, `ufw`...           | The tool a task uses                                               |
| Handler        | `Restart ssh`                     | A task that runs only if something notified it _and_ changed       |
| Variables      | `group_vars/pulsecheck/vars.yml`  | Settings, loaded automatically for the `pulsecheck` group          |
| Vault          | `group_vars/pulsecheck/vault.yml` | Encrypted secrets                                                  |
| Template       | `roles/pulsecheck/templates/*.j2` | Files with `{{ blanks }}` filled from variables                    |
| `become: true` | `site.yml`                        | Run tasks with sudo                                                |
| Idempotency    | everything                        | Running it again only changes what's drifted                       |

### 5.2 Inventory: `inventory/hosts.ini`

```ini
[pulsecheck]
pulsecheck-01 ansible_host=<elastic-ip>

[pulsecheck:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_ed25519
ansible_python_interpreter=/usr/bin/python3
```

- `ansible_user=ubuntu`: the default user on Ubuntu AMIs (Azure uses `azureuser`)
- The private key must be inside WSL's own `~/.ssh` with `chmod 600`. Keys under `/mnt/c` are rejected because Windows files look world-readable.

### 5.3 Playbook: `site.yml`

Runs the four roles in order, as root, against the `pulsecheck` group.

### 5.4 Roles

**common**: base setup

| Task                                  | Module            | Result                                                           |
| ------------------------------------- | ----------------- | ---------------------------------------------------------------- |
| Update apt cache and upgrade packages | `apt`             | Safe upgrade; cache reused for 1 hour                            |
| Install base packages                 | `apt`             | ca-certificates, curl, rsync, ufw, fail2ban, unattended-upgrades |
| Create / format / enable swap         | `command`, `file` | 2 GB `/swapfile` (only created once, thanks to `creates:`)       |
| Keep swap on after reboot             | `lineinfile`      | Adds the swap line to `/etc/fstab`                               |

**hardening**: security

| Task                                | Module    | Result                                                                                                                                    |
| ----------------------------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Lock down SSH                       | `copy`    | `/etc/ssh/sshd_config.d/10-hardening.conf`: no passwords, no root login, max 3 auth tries, no X11. Validated with `sshd -t` before saving |
| Allow SSH / Allow HTTP              | `ufw`     | Firewall rules for 22 and 80, added _before_ enabling                                                                                     |
| Enable firewall                     | `ufw`     | Deny all other incoming traffic                                                                                                           |
| fail2ban running                    | `service` | Bans IPs with repeated failed logins                                                                                                      |
| Never ban the admin IP _(if added)_ | `copy`    | `ignoreip` for `admin_ip`, so fail2ban can't lock you out                                                                                 |
| Handler: Restart ssh / fail2ban     | `service` | Only when the config actually changed                                                                                                     |

**docker**: container runtime

| Task                   | Module              | Result                                                        |
| ---------------------- | ------------------- | ------------------------------------------------------------- |
| Add Docker's apt repo  | `deb822_repository` | Official repo + signing key (newer than Ubuntu's own package) |
| Install Docker         | `apt`               | docker-ce, cli, containerd, buildx and compose plugins        |
| Docker running         | `service`           | Started and enabled on boot                                   |
| ubuntu in docker group | `user`              | Lets you run `docker` without sudo when you SSH in            |

**pulsecheck**: deploy the app

| Task                      | Module                | Result                                                                                                     |
| ------------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------- |
| Create app folder         | `file`                | `/opt/pulsecheck`, owned by ubuntu                                                                         |
| Copy app code             | `synchronize` (rsync) | Repo → server, excluding .git, .venv, .env, terraform, ansible. `--chmod=D755,F644` keeps permissions sane |
| Write .env                | `template` (`env.j2`) | Built from `pulsecheck_env` + vault; mode 0600                                                             |
| Write compose.prod.yaml   | `template`            | Overrides nginx to publish port 80 instead of 8080                                                         |
| Build and start the stack | `docker_compose_v2`   | Like `docker compose up -d --build`, waits up to 10 min for all containers to be healthy                   |
| Check the app answers     | `uri`                 | Calls `http://localhost/docs` until it gets a 200                                                          |

### 5.5 Variables: `group_vars/pulsecheck/vars.yml`

| Variable         | Value             | Used by                                                                |
| ---------------- | ----------------- | ---------------------------------------------------------------------- |
| `pulsecheck_dir` | `/opt/pulsecheck` | pulsecheck role                                                        |
| `swap_size`      | `2G`              | common role                                                            |
| `pulsecheck_env` | dict of env keys  | `env.j2` → `.env` on the server. Must match the keys in `.env.example` |
| `admin_ip`       | your IP `/32`     | fail2ban whitelist (if added)                                          |

The folder name `pulsecheck` matches the inventory group, which is why it's loaded automatically.

### 5.6 Vault

```bash
ansible-vault create ansible/group_vars/pulsecheck/vault.yml   # first time
ansible-vault edit   ansible/group_vars/pulsecheck/vault.yml   # change secrets
ansible-vault view   ansible/group_vars/pulsecheck/vault.yml   # read secrets
```

Contains `vault_postgres_password`. The vault password itself is **not recoverable**: if it's lost, delete `vault.yml` and create it again.

### 5.7 Commands

```bash
cd /mnt/f/DevopsProj/ansible-compose-uptime-monitor

# connectivity test
ansible -i ansible/inventory/hosts.ini pulsecheck -m ping

# check for YAML/syntax errors
ansible-playbook -i ansible/inventory/hosts.ini ansible/site.yml --syntax-check

# full run
ansible-playbook -i ansible/inventory/hosts.ini ansible/site.yml --ask-vault-pass
```

Reading the output: **green `ok`** = already correct, nothing done. **Yellow `changed`** = Ansible fixed something. **Red `failed`** = stopped; read the message.

**Note:** Ansible ignores an `ansible.cfg` in world-writable folders, and everything under `/mnt/f` counts as world-writable from WSL. If you add one, load it with `export ANSIBLE_CONFIG=$PWD/ansible/ansible.cfg`.

---

## 6. Which terminal for what

| Prompt                 | Where you are      | Use it for                     |
| ---------------------- | ------------------ | ------------------------------ |
| `Veron@...MINGW64`     | Git Bash (Windows) | terraform, aws, docker (local) |
| `ber0ng@...`           | WSL Ubuntu         | ansible, ansible-vault         |
| `ubuntu@ip-10-20-1-20` | The EC2 server     | looking around, logs           |

---

## 7. Day-to-day operations

| I want to...                            | Do this                                                                                             |
| --------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Deploy a code change                    | Commit locally, then rerun the playbook from WSL. It re-syncs and rebuilds                          |
| See the app                             | `http://<elastic-ip>/docs`                                                                          |
| SSH in                                  | `ssh ubuntu@<elastic-ip>`                                                                           |
| See containers                          | On the server: `cd /opt/pulsecheck && docker compose ps`                                            |
| Follow worker logs                      | `docker compose logs worker -f` (Ctrl+C to stop)                                                    |
| Check a health check                    | `docker inspect --format '{{json .State.Health}}' pulsecheck-worker-1 \| python3 -m json.tool`      |
| Start the server after the nightly stop | `aws ec2 start-instances --instance-ids <id>` or the EC2 console. Containers come back on their own |
| My home IP changed                      | Update `my_ip` in tfvars → `terraform apply` (and `admin_ip` → rerun playbook)                      |
| Shut it all down                        | `terraform destroy` in `terraform/aws`                                                              |

---

## 8. Troubleshooting log (things that actually broke)

| Symptom                                                         | Cause                                                                  | Fix                                                         |
| --------------------------------------------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------- |
| Azure: `NotAvailableForSubscription` / quota 0 for Bsv2 family  | New-subscription VM family limits                                      | Pivoted to AWS; Azure quota ticket pending                  |
| `Command 'ansible' not found`                                   | Ran it inside the EC2 server                                           | Run Ansible from WSL, not the server                        |
| `Unsupported parameters ... upgrade_cache`                      | Typo                                                                   | `update_cache: true`. The error lists every valid parameter |
| Worker `unhealthy`, `FileNotFoundError: /tmp/worker_heartbeat`  | Code wrote `/tmp/heartbeat`, health check read `/tmp/worker_heartbeat` | Made the paths match in `worker.py`                         |
| `kex_exchange_identification: Connection closed by remote host` | SSH dropped right after hardening, likely fail2ban banning your own IP | Wait ~10 min (ban expires), whitelist `admin_ip`            |
| "Create app folder" always `changed`                            | rsync copied 777 permissions from `/mnt/f`                             | `--chmod=D755,F644` in `rsync_opts`                         |

---

## 9. Security notes

- SSH: key-only, no root login, reachable only from `my_ip` (security group) + UFW + fail2ban.
- Secrets: in Ansible Vault in the repo; on the server only in `/opt/pulsecheck/.env` (mode 0600).
- Terraform state: in a private, versioned, encrypted S3 bucket.
- **Docker bypasses UFW** for published ports (it writes its own iptables rules). Fine here because only port 80 is published and the security group is the outer wall.
- Known gap: any URL can be added as a monitor, including internal addresses (SSRF). Acceptable for a personal tool.

## 10. Cost notes

- t3.micro + 20 GB gp3, auto-stopped nightly.
- `cpu_credits = standard` prevents surprise burst charges.
- The Elastic IP is billed hourly even while the instance is stopped. `terraform destroy` when not in use for a while.

---

## 11. Official documentation

- Terraform AWS provider: https://registry.terraform.io/providers/hashicorp/aws/latest/docs
- Terraform S3 backend: https://developer.hashicorp.com/terraform/language/backend/s3
- Ansible getting started: https://docs.ansible.com/ansible/latest/getting_started/index.html
- Ansible playbooks: https://docs.ansible.com/ansible/latest/playbook_guide/index.html
- Ansible Vault: https://docs.ansible.com/ansible/latest/vault_guide/index.html
- Module docs: search "ansible.builtin.apt", "community.general.ufw", "community.docker.docker_compose_v2"
- Docker Compose: https://docs.docker.com/compose/
