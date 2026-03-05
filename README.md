This is a Terraform setup that deploys a configurable number of EC2
instances that run a prebuilt podman image pulled from S3.

Each instance runs the same image twice: Jupyter Lab (port 8888) and
Opencode's web interface (port 3000).

Datasets are uploaded as a tar.gz to S3, pulled down on boot, and mounted
read-only into both containers at `/data`.

Teams are color coded via `team-colors.txt`. `deploy.sh` defaults the
instance count to the number of colors in that file, but you can override
it with `INSTANCE_COUNT` or `--team-count`.

Subdomains are mapped from `team-colors.txt` in order. For example, the
first color maps to `blue.caiphdatathon.live`, the second to
`orange.caiphdatathon.live`, etc. See `namecheap_sync_dns.py` for the
exact mapping table and overrides.




AI Slop:
========

# AWS Infrastructure-as-Code: EC2 + Podman + Caddy with HTTPS (Namecheap DNS)

This Terraform module deploys a fleet of Ubuntu EC2 instances, pulls and
runs a prebuilt container image tarball from S3, and exposes two separate
services per instance. Caddy is always enabled for HTTPS termination.

DNS is assumed to be managed externally (e.g., Namecheap). After applying
Terraform, create A records at your DNS provider for
`team01.<your-domain>`, `team02.<your-domain>`, etc., pointing to the
public IPs output by Terraform.

Each instance is assigned a public IP (configurable) and is reachable
only from your detected public IPv4 (/32) on the configured ports by default
(suitable for testing via direct IP access). You can override this behavior by
providing an explicit `allow_cidrs` list.
TLS ports can be managed separately with `tls_allow_cidrs` so you can keep
app ports restricted while allowing public HTTPS/ACME validation on 80/443.
Route 53 is not used in this configuration. If you prefer Route 53-managed
DNS and automatic record creation, that can be added, but this module is
set up to work with external DNS (e.g., Namecheap) out of the box.

> Note on TLS challenges
>
> Caddy obtains certificates via Let’s Encrypt using the HTTP‑01 challenge by
> default, which requires inbound connectivity on ports 80 and 443 from the
> Let’s Encrypt validation network. Because inbound access is restricted to
> your detected public IP for testing, issuance will fail until you temporarily
> broaden 80/443 (e.g., allow `0.0.0.0/0`) or switch Caddy to DNS‑01.
> Use `tls_allow_cidrs = ["0.0.0.0/0"]` to keep only TLS ports public. For
> initial IP testing, use `http://<instance_ip>:8888` and `http://<instance_ip>:3000`.

## Prerequisites

* **Terraform ≥ 1.5** installed locally.
* **AWS CLI v2** installed and configured for the target account/region.
* A prebuilt container image archive (`container-image.tgz` locally),
  created with `./datathon_container/build_and_export.sh` and uploaded
  with `./upload_image.sh` to the bucket
  `podman-build-context-<account-id>-<region>` as `container-image.tar.gz`.
* `env.txt` in the same bucket (key `env.txt`) – environment file passed
  to containers at runtime (uploaded by `upload_image.sh`).
* A datasets archive (`data_sets.tgz` locally) uploaded with
  `upload_datasets.sh` to the same bucket under key `data_sets.tar.gz`.
* Optional persistent workspace volumes (EBS) can be created and are mounted
  into both containers at `/workspace` for user code and notebooks.
* No separate allowlist file is needed. Terraform auto-detects your public
  IPv4 and restricts inbound access to that /32 on the configured ports.
* A **registered domain** (e.g. `caiphdatathon.live`). DNS is managed at
  your registrar (e.g., Namecheap).

## Structure of this repository

```
.
├── main.tf               # Core infrastructure: VPC data, IAM, SG, EC2
├── variables.tf          # Input variables
├── outputs.tf            # Useful outputs (IPs, FQDNs, Namecheap DNS map)
├── user_data.sh.tftpl    # Cloud‑init script rendered by Terraform
├── datathon_container/   # Example application Containerfile and assets
└── README.md             # This document
```

## Quick start

1. **Build and upload the image and datasets**:

   ```bash
   ./datathon_container/build_and_export.sh
   ./upload_image.sh ./container-image.tgz
   ./upload_datasets.sh ./data_sets.tgz
   ```

2. **Run the one‑click deploy** (defaults instance count to the number of
   lines in `team-colors.txt`):

   ```bash
   ./deploy.sh
   ```

   To override count for a single run:

   ```bash
   ./deploy.sh --team-count 3
   ```

   Terraform will display the public and private IPs of your instances and
   the generated sub‑domains (e.g. `team01.caiphdatathon.live`). It also
   outputs per-instance Jupyter tokens (sensitive output `jupyter_tokens`).

4. **Create DNS A records at Namecheap.** After apply, Terraform prints
   outputs showing public IPs and the expected sub‑domains, and also writes
   a helper file `namecheap_dns_<domain>.txt` in this directory with a
   CSV you can paste. Create A records in Namecheap for each instance, e.g.:

   - `team01.caiphdatathon.live` → `<public_ip_of_instance_1>`
   - `team02.caiphdatathon.live` → `<public_ip_of_instance_2>`

   Use the `dns_records` output as a reference.

5. **Access your services over direct IP ports** (default path):

   ```
   http://<instance_ip>:8888
   http://<instance_ip>:3000
   ```

   Caddy is installed by default and serves HTTPS on each team subdomain
   (`blue.<domain>`, `orange.<domain>`, etc.), routing `/jupyter` to Jupyter
   and all other paths to Opencode. Ensure DNS and ports 80/443 are open.

6. **(Optional) Sync Namecheap DNS automatically** for team subdomains:

   ```bash
   export NAMECHEAP_API_USER=your_api_user
   export NAMECHEAP_API_KEY=your_api_key
   export NAMECHEAP_USERNAME=your_username
   # optional: NAMECHEAP_CLIENT_IP (auto-detected if not set)
   export DOMAIN=caiphdatathon.live
   ./namecheap_sync_dns.py
   ```

   This reads `team-colors.txt` and `terraform output instance_public_ips`,
   then updates A records for the team subdomains. Set `DRY_RUN=true` to
   preview changes, or `TEAM_NAMES=blue,orange,...` to override names.

## Customisation

* **No public IPs:** Set `associate_public_ip = false` to avoid
  associating public IP addresses with your instances.  You will
  need a load balancer, VPN or AWS Systems Manager Session Manager to
  reach them.

* **Image source (hard-coded):** This module always downloads a prebuilt
  image tarball from S3 at bucket `podman-build-context-<account-id>-<region>`
  and key `container-image.tar.gz`. Use `datathon_container/build_and_export.sh`
  and `upload_image.sh` to produce and upload it.

* **Additional S3 read permissions:** The IAM policy grants read access only
  to the runtime artifacts in the build-context bucket (image tarball,
  env.txt, datasets archive). If your container needs to fetch more data at
  build or runtime, expand the policy accordingly (e.g. grant access to a prefix).

* **No build-context zip:** The instance does not build from `build-context.zip`.
  The bootstrap path loads a prebuilt image tar instead.

* **Custom Caddy configuration:** Edit `user_data.sh.tftpl` if you
  need different routing logic, TLS settings, or DNS challenge
  providers.

* **Jupyter tokens:** Each instance gets a unique random token. Terraform
  outputs them as a sensitive list (`jupyter_tokens`), they are included in
  the generated `namecheap_dns_<domain>.txt` helper file, and are written on
  instance at `/opt/appbuild/jupyter_token.txt`.

## Cleanup

To destroy everything created by this module, run:

```bash
terraform destroy -auto-approve
```

If you created a public hosted zone and no longer need it, remove the
domain registration or change its nameservers as appropriate.
### Controlling inbound access

By default, inbound access on the configured ports is restricted to your
detected public IPv4 (/32) at plan/apply time. To open access to a wider
audience (e.g., an event), set one or both of the following in
`terraform.tfvars`:

```
# Disable auto-detection and provide explicit CIDRs
auto_allow_caller_ip = false
allow_cidrs = [
  "0.0.0.0/0",          # world (use with care)
  # "203.0.113.45/32",  # or specific IPs/ranges
]
```

If `allow_cidrs` is non-empty, it always overrides auto-detection. If you set
`auto_allow_caller_ip = false`, you must provide `allow_cidrs`.
