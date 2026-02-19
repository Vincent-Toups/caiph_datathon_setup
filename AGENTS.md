Agent Notes for This Repository

Scope and Purpose
- This repo provisions EC2 instances that build and run a containerized data/ML stack (Jupyter + Opencode) behind Caddy, with DNS managed externally (Namecheap).
- Terraform applies from this working directory; helper scripts automate upload, deploy, debugging, and (optionally) SSH enablement.

Core Conventions
- DNS: Managed in Namecheap. Route53 resources are intentionally removed. Terraform emits a local file `namecheap_dns_<domain>.txt` listing A records and Jupyter tokens.
- Build inputs: Always pulled from S3 bucket `podman-build-context-<account-id>-<region>` with fixed keys:
  - `build-context.zip` (zipped build context)
  - `env.txt` (runtime env file)
- Security: Inbound ports default to caller IP (/32) auto-detected at apply time. Override with `allow_cidrs` to broaden.
- Tokens: Each instance gets a randomized Jupyter token (Terraform `random_password`). Tokens surface in outputs (sensitive), the DNS helper file, and on-instance at `/opt/appbuild/jupyter_token.txt`.

Important Implementation Details
- Cloud-init templating: user_data is rendered with Terraform `templatefile`. Any bash variable expansions must be escaped with double-dollar (e.g., `$${VAR}`) to avoid Terraform interpolation.
- Logging: Bootstrap logs stream to `/var/log/datathon-setup.log` and systemd journal (tag `datathon-setup`). Prefer these for troubleshooting.
- Networking: App ports are published to the host (`-p 8888:8888`, `-p 3000:3000`) for direct IP tests before DNS/TLS.

Helper Scripts
- `deploy.sh`: One-click path that uploads `datathon_container` build context, pushes `env.txt`, generates minimal tfvars, runs `terraform init/apply`, and prints next steps.
- `debug.sh`: Collects diagnostics (S3 presence, Terraform providers/state/outputs, EC2 describe, console logs, basic reachability) under `debug/<timestamp>/`.
- `tmp.sh`: Enables SSH by attaching the first discovered EC2 key pair and opening port 22 to your IP; re-applies Terraform and waits for SSH.

CLI Container
- Root `Containerfile` builds a CLI image with AWS CLI + Terraform (downloaded binary) and utilities (zip/unzip/jq). Use `start.sh` to run it.

Common Tasks
- First run: `podman build -t aws-cli . && ./start.sh && ./deploy.sh`
- Enable SSH: `./tmp.sh sshkey` (ensure the private key file matches your EC2 key pair)
- Debug: `./debug.sh` and inspect the latest `debug/<timestamp>/` directory

Coding Guidelines
- Keep Terraform changes minimal and explicit. Favor variables with sensible defaults; add toggles only when necessary.
- Avoid introducing Route53 or DNS providers unless explicitly requested.
- When editing `user_data.sh.tftpl`, always escape bash variables intended for runtime with `$${...}`.
- Prefer logging meaningful milestones; don’t spam logs.

Secrets
- Do not commit real credentials. `env.txt` in this repo is for local testing only—rotate any leaked keys.
- Terraform state may contain sensitive outputs (tokens). Use secure backends in real deployments.

Validation
- After changes: run `terraform init -upgrade` and a test `terraform plan`.
- Use `./debug.sh` to confirm reachability and logs if a test apply is performed.

