terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.1"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Lookup the default VPC and its subnets.  You can override
# these by supplying your own subnet_ids if you prefer a
# bespoke VPC topology.  The default VPC keeps the example
# simple.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

##
## Base AMI: Ubuntu 22.04 LTS (amd64)
##
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

data "aws_ec2_instance_type_offerings" "available_azs" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

##
## Allowlist: detect the caller's public IPv4 and restrict access
## to that /32 for the configured ports. Suitable for testing via IP.
##
data "http" "caller_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  detected_caller_cidr = "${trimspace(chomp(data.http.caller_ip.response_body))}/32"
  allow_cidrs          = length(var.allow_cidrs) > 0 ? var.allow_cidrs : (var.auto_allow_caller_ip ? [local.detected_caller_cidr] : [])
  tls_ports            = toset([80, 443])
  app_ports            = toset([for p in var.ports : p if !contains(local.tls_ports, p)])
  active_tls_ports     = toset([for p in var.ports : p if contains(local.tls_ports, p)])
  tls_allow_cidrs      = length(var.tls_allow_cidrs) > 0 ? var.tls_allow_cidrs : local.allow_cidrs
}

##
## Build context S3 location (hard-coded convention used by upload script)
## bucket: podman-build-context-<account>-<region>
## key:    build-context.zip
##
data "aws_caller_identity" "current" {}

locals {
  build_context_bucket = "podman-build-context-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  build_context_key    = "build-context.zip"
  env_key              = "env.txt"
  image_tar_key        = "container-image.tar.gz"
  datasets_key         = "data_sets.tar.gz"
  code_key             = "code.tar.gz"
  code_backup_prefix   = "code-backups"
  data_volume_device   = "/dev/sdf"
  workspace_host_dir   = "/opt/workspace"
  workspace_container  = "/datathon"
  eligible_subnet_ids = [
    for id in data.aws_subnets.default.ids : id
    if contains(data.aws_ec2_instance_type_offerings.available_azs.locations, data.aws_subnet.default[id].availability_zone)
  ]
  subnet_ids = local.eligible_subnet_ids
  subnet_azs = { for id in local.subnet_ids : id => data.aws_subnet.default[id].availability_zone }
  instance_azs = [
    for i in range(var.instance_count) :
    local.subnet_azs[local.subnet_ids[i % length(local.subnet_ids)]]
  ]
  team_colors_raw = fileexists("${path.module}/team-colors.txt") ? split("\n", trimspace(file("${path.module}/team-colors.txt"))) : []
  team_colors     = [for c in local.team_colors_raw : trimspace(c) if trimspace(c) != ""]
  color_to_name = {
    "#1E90FF" = "blue"
    "#FF8C00" = "orange"
    "#2E8B57" = "green"
    "#DC143C" = "red"
    "#8A2BE2" = "purple"
    "#00CED1" = "cyan"
    "#FFD700" = "gold"
    "#A52A2A" = "brown"
    "#00FF7F" = "springgreen"
    "#FF1493" = "deeppink"
  }
  team_slugs = [
    for c in local.team_colors :
    replace(replace(lower(trimspace(c)), " ", "-"), "_", "-")
  ]
  team_labels_from_colors = [
    for idx, c in local.team_colors :
    (startswith(trimspace(c), "#")
      ? lookup(local.color_to_name, upper(trimspace(c)), format("team%02d", idx + 1))
      : (length(local.team_slugs[idx]) > 0 ? local.team_slugs[idx] : format("team%02d", idx + 1))
    )
  ]
  team_labels = [
    for i in range(var.instance_count) :
    (i < length(local.team_labels_from_colors) ? local.team_labels_from_colors[i] : format("team%02d", i + 1))
  ]
}

##
## IAM role and policies.  The EC2 instances need permission
## to fetch build inputs from S3.  Only the specified object
## keys are granted.
##
data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "${var.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

data "aws_iam_policy_document" "s3_read" {
  statement {
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${local.build_context_bucket}/${local.env_key}",
      "arn:aws:s3:::${local.build_context_bucket}/${local.image_tar_key}",
      "arn:aws:s3:::${local.build_context_bucket}/${local.datasets_key}",
      "arn:aws:s3:::${local.build_context_bucket}/${local.code_key}",
    ]
  }

  statement {
    actions = ["s3:PutObject"]
    resources = [
      "arn:aws:s3:::${local.build_context_bucket}/${local.code_backup_prefix}/*",
    ]
  }
}

resource "aws_iam_policy" "s3_read" {
  name   = "${var.name_prefix}-s3-read"
  policy = data.aws_iam_policy_document.s3_read.json
}

resource "aws_iam_role_policy_attachment" "attach_s3_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_read.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.name_prefix}-instance-profile"
  role = aws_iam_role.ec2_role.name
}

##
## Security group.  Only the ports listed in var.ports
## are opened to the allowlisted CIDRs.  Egress is unrestricted.
##
resource "aws_security_group" "svc" {
  name        = "${var.name_prefix}-svc-sg"
  description = "Allow inbound only from allowlist CIDRs"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = local.app_ports
    content {
      description = "allowed app/ssh port"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = local.allow_cidrs
    }
  }

  dynamic "ingress" {
    for_each = local.active_tls_ports
    content {
      description = "allowed tls/acme port"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = local.tls_allow_cidrs
    }
  }

  egress {
    description = "egress all"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    precondition {
      condition     = length(local.allow_cidrs) > 0
      error_message = "No inbound CIDRs configured. Provide allow_cidrs or enable auto_allow_caller_ip."
    }
    precondition {
      condition     = length(local.active_tls_ports) == 0 || length(local.tls_allow_cidrs) > 0
      error_message = "TLS ports are enabled but no TLS CIDRs are configured. Provide tls_allow_cidrs (recommended 0.0.0.0/0 for ACME) or ensure allow_cidrs is non-empty."
    }
  }
}

##
## EC2 instances.  Each instance builds and runs the provided
## Containerfile using podman, then launches a Caddy reverse proxy
## with automatic HTTPS using Let’s Encrypt.  The subdomain is
## derived from team labels (from team-colors.txt when present).
##
resource "aws_instance" "node" {
  count                       = var.instance_count
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_ids[count.index % length(local.subnet_ids)]
  vpc_security_group_ids      = [aws_security_group.svc.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = var.associate_public_ip
  key_name                    = var.ssh_key_name

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region          = var.aws_region
    buildctx_bucket     = local.build_context_bucket
    buildctx_key        = local.build_context_key
    env_key             = local.env_key
    image_tar_key       = local.image_tar_key
    datasets_key        = local.datasets_key
    code_key            = local.code_key
    code_backup_prefix  = local.code_backup_prefix
    data_volume_device  = local.data_volume_device
    workspace_host_dir  = local.workspace_host_dir
    workspace_container = local.workspace_container
    jupyter_token       = random_password.jupyter_token[count.index].result
    image_name          = var.image_name
    run1_name           = var.run1_name
    run2_name           = var.run2_name
    run1_cmd            = var.run1_cmd
    run2_cmd            = var.run2_cmd
    domain_name         = var.domain_name
    instance_index      = count.index
    team_name           = local.team_labels[count.index]
    env_hash            = var.env_hash
  })

  tags = {
    Name = "${var.name_prefix}-${count.index}"
  }

  lifecycle {
    precondition {
      condition     = length(local.subnet_ids) > 0
      error_message = "No subnets found in AZs that support instance type ${var.instance_type}. Choose a different instance type or AZ."
    }
  }
}

##
## Persistent data volumes (one per instance). These are optional and
## intended to survive instance replacement.
##
locals {
  desired_volume_names = [for i in range(var.instance_count) : "${var.name_prefix}-data-${i}"]
}

locals {
  volume_index_by_name = {
    for i, n in local.desired_volume_names : n => i
  }
  desired_volume_map = { for n in local.desired_volume_names : n => n }
}

data "aws_ebs_volumes" "data_by_name" {
  for_each = toset(local.desired_volume_names)

  filter {
    name   = "tag:Name"
    values = [each.key]
  }

  filter {
    name   = "tag:TeamIndex"
    values = [tostring(local.volume_index_by_name[each.key])]
  }

  filter {
    name   = "status"
    values = ["available", "in-use"]
  }

  filter {
    name   = "availability-zone"
    values = [local.instance_azs[local.volume_index_by_name[each.key]]]
  }
}

locals {
  existing_volume_ids_by_name = {
    for k, v in data.aws_ebs_volumes.data_by_name :
    k => (length(v.ids) > 0 ? v.ids[0] : null)
  }
}

resource "aws_ebs_volume" "data" {
  for_each          = var.create_data_volumes ? local.desired_volume_map : {}
  availability_zone = local.instance_azs[local.volume_index_by_name[each.key]]
  size              = var.data_volume_size_gb
  type              = "gp3"

  tags = {
    Name      = each.key
    TeamIndex = tostring(local.volume_index_by_name[each.key])
  }
}

resource "time_sleep" "wait_for_data_volumes" {
  depends_on      = [aws_ebs_volume.data]
  create_duration = "20s"
}

locals {
  data_volume_ids_by_name = var.create_data_volumes ? (
    { for k, v in aws_ebs_volume.data : k => v.id }
    ) : (
    { for k, v in local.existing_volume_ids_by_name : k => v if v != null }
  )

  data_volume_attachments = {
    for name, id in local.data_volume_ids_by_name :
    name => {
      id    = id
      index = local.volume_index_by_name[name]
    }
  }
}

resource "aws_volume_attachment" "data" {
  for_each    = local.data_volume_attachments
  device_name = local.data_volume_device
  volume_id   = each.value.id
  instance_id = aws_instance.node[each.value.index].id
  depends_on  = [time_sleep.wait_for_data_volumes]
}

## Per-instance Jupyter tokens
resource "random_password" "jupyter_token" {
  count   = var.instance_count
  length  = 32
  special = false
}

##
## DNS is managed externally (e.g., Namecheap).
## Create A records like red.<domain_name> pointing to each
## instance's public IP using the outputs after apply.
##

##
## Generate a local file with Namecheap DNS instructions and CSV
## so you can quickly add A records for each instance.
##
locals {
  dns_full_records = [
    for idx in range(var.instance_count) :
    format(" - %s A %s (TTL 60)", format("%s.%s", local.team_labels[idx], var.domain_name), aws_instance.node[idx].public_ip)
  ]

  dns_csv_lines = [
    for idx in range(var.instance_count) :
    format("%s,A,%s,60", local.team_labels[idx], aws_instance.node[idx].public_ip)
  ]

  namecheap_dns_text = <<-EOT
  Namecheap DNS setup for ${var.domain_name}

  Create the following A records in Namecheap (Domain List -> Manage -> Advanced DNS):
  ${join("\n", local.dns_full_records)}

  CSV (Host,Type,Value,TTL):
  Host,Type,Value,TTL
  ${join("\n", local.dns_csv_lines)}

  Jupyter tokens (per instance):
  ${join("\n", [for idx in range(var.instance_count) : format(" - %s: %s", local.team_labels[idx], random_password.jupyter_token[idx].result)])}

  Notes:
  - Host is just the subdomain label (e.g., blue), not the full FQDN.
  - Keep TTL at 60 during setup for faster propagation.
  - Caddy is enabled by default; ensure inbound ports 80 and 443 are open for TLS.
  EOT
}

resource "local_file" "namecheap_dns" {
  filename = "${path.module}/namecheap_dns_${var.domain_name}.txt"
  content  = local.namecheap_dns_text
}
