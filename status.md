Project Status — Datathon Infra (Namecheap DNS)

Last Updated: $(date -Is)

Summary
- Terraform config refactored to assume external DNS (Namecheap) and a fixed S3 build-context convention.
- Deploy automation (`deploy.sh`) and diagnostics (`debug.sh`) added; SSH enabler (`tmp.sh`) available.
- Strong defaults set for domain, ports, image name, run commands; per-instance randomized Jupyter tokens implemented.

Current Deployment
- Instance state: running (from latest debug bundle)
  - Public IP: 44.201.154.32
  - Security Group: `teamnode-svc-sg`
    - Inbound allowed only from 149.40.50.118/32 on ports 80, 443, 8888, 3000 (22 closed by default)
- DNS: Namecheap not yet configured; Terraform wrote `namecheap_dns_caiphdatathon.live.txt` for later use.
- Reachability: ports 80/443/8888/3000 currently not responding — expected while the container image builds on first boot.

Local Files and Scripts
- `namecheap_dns_caiphdatathon.live.txt`: A-record instructions + Jupyter tokens.
- `deploy.sh`: Uploads build context and env, applies Terraform with sane defaults.
- `debug.sh`: Wrote bundle under `debug/<timestamp>/` (contains state, SG, reachability, etc.). Latest shows no port responses yet.
- `tmp.sh`: Enables SSH by attaching your EC2 key pair and opening port 22; replaces the instance if needed.

Bootstrap Logging
- On-instance: `/var/log/datathon-setup.log` (also mirrored to system journal with tag `datathon-setup`).
- Without SSH, EC2 console output may not show full logs on Ubuntu images; rely on reachability or enable SSH/SSM.

Key Design Decisions
- Removed Route53 resources; Namecheap is authoritative.
- Always use S3 bucket `podman-build-context-<account>-<region>` for:
  - `build-context.zip` (uploaded from `datathon_container` via `upload_container_stuff.sh`)
  - `env.txt` (empty allowed for tests)
- Security group CIDRs: auto-detected caller IP by default; override via `ALLOW_CIDRS` or `allow_cidrs` variable.
- App ports published to host for direct IP testing prior to HTTPS.

Next Steps
- Wait for the build to complete; re-run `curl -I http://44.201.154.32:8888` and `:3000` until responsive.
- Optional: speed up the build by temporarily using a larger instance type and re-applying.
- If you need shell access now: `./tmp.sh sshkey` (uses your only EC2 key pair; opens port 22 and replaces the instance if needed).
- After services are up: create Namecheap A records using `namecheap_dns_caiphdatathon.live.txt`. For Let’s Encrypt, temporarily broaden 80/443 if needed.

