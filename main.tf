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

##
## Base AMI: Ubuntu 22.04 LTS (amd64)
##
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
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
    for_each = toset(var.ports)
    content {
      description = "allowed port"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = local.allow_cidrs
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
  }
}

##
## EC2 instances.  Each instance builds and runs the provided
## Containerfile using podman, then launches a Caddy reverse proxy
## with automatic HTTPS using Let’s Encrypt.  The subdomain is
## derived from the instance index (team01, team02, …).
##
resource "aws_instance" "node" {
  count                       = var.instance_count
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[count.index % length(data.aws_subnets.default.ids)]
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
    aws_region      = var.aws_region
    buildctx_bucket = local.build_context_bucket
    buildctx_key    = local.build_context_key
    env_key         = local.env_key
    image_tar_key   = local.image_tar_key
    jupyter_token   = random_password.jupyter_token[count.index].result
    image_name      = var.image_name
    run1_name       = var.run1_name
    run2_name       = var.run2_name
    run1_cmd        = var.run1_cmd
    run2_cmd        = var.run2_cmd
    domain_name     = var.domain_name
    instance_index  = count.index
    enable_caddy    = var.enable_caddy ? "true" : "false"
  })

  tags = {
    Name = "${var.name_prefix}-${count.index}"
  }
}

## Per-instance Jupyter tokens
resource "random_password" "jupyter_token" {
  count   = var.instance_count
  length  = 32
  special = false
}

##
## DNS is managed externally (e.g., Namecheap).
## Create A records like team01.<domain_name> pointing to each
## instance's public IP using the outputs after apply.
##

##
## Generate a local file with Namecheap DNS instructions and CSV
## so you can quickly add A records for each instance.
##
locals {
  dns_full_records = [
    for idx in range(var.instance_count) :
    format(" - %s A %s (TTL 60)", format("team%02d.%s", idx + 1, var.domain_name), aws_instance.node[idx].public_ip)
  ]

  dns_csv_lines = [
    for idx in range(var.instance_count) :
    format("team%02d,A,%s,60", idx + 1, aws_instance.node[idx].public_ip)
  ]

  namecheap_dns_text = <<-EOT
  Namecheap DNS setup for ${var.domain_name}

  Create the following A records in Namecheap (Domain List -> Manage -> Advanced DNS):
  ${join("\n", local.dns_full_records)}

  CSV (Host,Type,Value,TTL):
  Host,Type,Value,TTL
  ${join("\n", local.dns_csv_lines)}

  Jupyter tokens (per instance):
  ${join("\n", [for idx in range(var.instance_count) : format(" - team%02d: %s", idx + 1, random_password.jupyter_token[idx].result)])}

  Notes:
  - Host is just the subdomain label (e.g., team01), not the full FQDN.
  - Keep TTL at 60 during setup for faster propagation.
  - If enable_caddy=true, ensure inbound ports 80 and 443 are open appropriately for your TLS strategy.
  EOT
}

resource "local_file" "namecheap_dns" {
  filename = "${path.module}/namecheap_dns_${var.domain_name}.txt"
  content  = local.namecheap_dns_text
}
