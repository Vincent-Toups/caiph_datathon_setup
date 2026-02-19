This is a terraform setup I built with the assistance of codex which
deploys a configurable number of EC2 instances which run a podman
container pulled from s3.

Each instance runs the container twice: jupyter lab and opencode's web
interface.

So this basically works. Missing pieces:

Upload the zip of the datasets to s3, pull the datasets down to the
containers and put them someplace. How should we handle files?
Presently we don't mount any volumes in the container.

Nice to have: I have bought caiph_datahon.live and it would be nice to
point sub-domains to the instances, eg:

opencode_red.caiph_datathon.live 
jupyter_red.caiph_datathon.live 

etc

Teams are color coded.




AI Slop:
========

# AWS Infrastructure-as-Code: EC2 + Podman + Caddy with HTTPS (Namecheap DNS)

This Terraform module deploys a fleet of Ubuntu EC2 instances, builds and
runs a containerised application from a zipped build context stored in S3, and
exposes two separate services under per-instance sub‑domains using
[Caddy](https://caddyserver.com/) for automatic TLS via Let’s Encrypt.

DNS is assumed to be managed externally (e.g., Namecheap). After applying
Terraform, create A records at your DNS provider for
`team01.<your-domain>`, `team02.<your-domain>`, etc., pointing to the
public IPs output by Terraform.

Each instance is assigned a public IP (configurable) and is reachable
only from your detected public IPv4 (/32) on the configured ports by default
(suitable for testing via direct IP access). You can override this behavior by
providing an explicit `allow_cidrs` list.
Route 53 is not used in this configuration. If you prefer Route 53-managed
DNS and automatic record creation, that can be added, but this module is
set up to work with external DNS (e.g., Namecheap) out of the box.

> Note on TLS challenges
>
> Caddy obtains certificates via Let’s Encrypt using the HTTP‑01 challenge by
> default, which requires inbound connectivity on ports 80 and 443 from the
> Let’s Encrypt validation network. Because inbound access is restricted to
> your detected public IP for testing, issuance will fail until you temporarily
> broaden 80/443 (e.g., allow `0.0.0.0/0`) or switch Caddy to DNS‑01. For
> initial IP testing, use `http://<instance_ip>:8888` and `http://<instance_ip>:3000`.

## Prerequisites

* **Terraform ≥ 1.5** installed locally.
* **AWS CLI v2** installed and configured for the target account/region.
* A zipped container build context in S3, created with the included
  `upload_container_stuff.sh` script. The script uploads to a bucket
  named `podman-build-context-<account-id>-<region>` (creating it if
  needed) with key `build-context.zip`.
* `env.txt` in the same bucket (key `env.txt`) – environment file passed
  to containers at runtime.
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

1. **Copy the module** somewhere convenient and change into that directory:

   ```bash
   mkdir -p ~/terraform/projects/mycluster
   cp -r aws_iac/* ~/terraform/projects/mycluster
   cd ~/terraform/projects/mycluster
   ```

2. **Create a `terraform.tfvars` file** describing your deployment. At a
   minimum set the instance count, instance type, and the domain name. Ports
   and run commands default to `80,443,8888,3000` and Jupyter/Opencode. For
   example:

   ```hcl
   # Instances
   instance_count = 1
   instance_type  = "t3.medium"

   # Domain used by Caddy for HTTPS (default provided)
   domain_name = "caiphdatathon.live"
   ```

   DNS is managed at your registrar (e.g., Namecheap). No Route 53 resources
   are created by this module.

3. **Initialise and apply** the Terraform configuration:

   ```bash
   terraform init
   terraform apply -auto-approve
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

5. **Access your services over HTTPS.** Once DNS propagates and Let’s Encrypt
   issues certificates (Caddy handles this automatically), you should be able
   to browse to:

   ```
   https://team01.caiphdatathon.live/jupyter
   https://team01.caiphdatathon.live/opencode
   ```

   Replace `team01` with `team02`, `team03`, etc. for additional nodes.

## Customisation

* **No public IPs:** Set `associate_public_ip = false` to avoid
  associating public IP addresses with your instances.  You will
  need a load balancer, VPN or AWS Systems Manager Session Manager to
  reach them.

* **Build context source (hard-coded):** This module always downloads a
  zipped build context from S3 at bucket `podman-build-context-<account-id>-<region>`
  and key `build-context.zip`. Use `upload_container_stuff.sh` from your
  datathon_container directory to prepare and upload this zip.

* **Additional S3 read permissions:** The IAM policy grants read access only
  to the zipped build context (`build-context.zip`) and your `env.txt` in the
  same bucket. If your container needs to fetch more data at build or runtime,
  expand the policy accordingly (e.g. grant access to a prefix).

* **Zipped build context only:** Using a single `Containerfile` path is not
  supported here; the system always uses the zipped build context convention
  described above.

* **Custom Caddy configuration:** Edit `user_data.sh.tftpl` if you
  need different routing logic, TLS settings, or DNS challenge
  providers.  See the Caddy documentation for details.

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
