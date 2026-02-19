variable "name_prefix" {
  description = "Prefix used for resource naming."
  type        = string
  default     = "teamnode"
}

variable "aws_region" {
  description = "AWS region in which to deploy resources."
  type        = string
  default     = "us-east-1"
}

variable "instance_count" {
  description = "Number of EC2 instances to launch."
  type        = number
}

variable "instance_type" {
  description = "EC2 instance type (e.g., t3.micro, g5.xlarge)."
  type        = string
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB for each EC2 instance."
  type        = number
  default     = 64
}

variable "ssh_key_name" {
  description = "Optional EC2 key pair name for SSH access.  Leave null to skip key attachment."
  type        = string
  default     = null
}

variable "associate_public_ip" {
  description = "Associate a public IP address with each instance.  You can disable this when using a load balancer or VPN."
  type        = bool
  default     = true
}

variable "ports" {
  description = "List of TCP ports to allow inbound from the allowlist. Defaults to SSH + direct app ports."
  type        = list(number)
  default     = [22, 8888, 3000]
}

variable "enable_caddy" {
  description = "Whether to install and run Caddy reverse proxy on each instance."
  type        = bool
  default     = false
}

variable "auto_allow_caller_ip" {
  description = "If true, automatically allow only the caller's public IPv4 (/32). If false, you must provide allow_cidrs."
  type        = bool
  default     = true
}

variable "allow_cidrs" {
  description = "Optional explicit list of CIDR ranges allowed inbound on the configured ports. When non-empty, overrides auto_allow_caller_ip."
  type        = list(string)
  default     = []
}

## Build context is always fetched from a zipped archive in S3
## using the convention: bucket "podman-build-context-<account>-<region>",
## key "build-context.zip". No overrides are supported here.

variable "image_name" {
  description = "Name (including tag) for the built container image."
  type        = string
  default     = "datathon:latest"
}

variable "run1_name" {
  description = "Container name for the first application."
  type        = string
  default     = "jupyter"
}

variable "run2_name" {
  description = "Container name for the second application."
  type        = string
  default     = "opencode"
}

variable "run1_cmd" {
  description = "Command for the first application.  This will be executed via bash -lc inside the container."
  type        = string
  default     = "jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root"
}

variable "run2_cmd" {
  description = "Command for the second application.  This will be executed via bash -lc inside the container."
  type        = string
  default     = "/root/.opencode/bin/opencode web --port 3000 --hostname 0.0.0.0"
}

variable "domain_name" {
  description = "Base domain to use for HTTPS (e.g., caiphdatathon.live).  Each instance will serve at team01.<domain_name>, team02.<domain_name>, etc."
  type        = string
  default     = "caiphdatathon.live"
}
