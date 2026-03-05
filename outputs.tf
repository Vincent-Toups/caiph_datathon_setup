output "instance_public_ips" {
  description = "Public IP addresses of the EC2 instances."
  value       = [for i in aws_instance.node : i.public_ip]
}

output "instance_private_ips" {
  description = "Private IP addresses of the EC2 instances."
  value       = [for i in aws_instance.node : i.private_ip]
}

output "subdomain_fqdns" {
  description = "Fully-qualified domain names for each instance (teamXX.<domain_name>)."
  value       = [for idx in range(var.instance_count) : format("%s.%s", local.team_labels[idx], var.domain_name)]
}

output "dns_records" {
  description = "Suggested DNS A records to create at your DNS provider (e.g., Namecheap)."
  value = [
    for idx in range(var.instance_count) : {
      name  = format("%s.%s", local.team_labels[idx], var.domain_name)
      type  = "A"
      value = aws_instance.node[idx].public_ip
      ttl   = 60
    }
  ]
}

output "jupyter_tokens" {
  description = "Random Jupyter tokens per instance (aligned with subdomain_fqdns order)."
  value       = [for idx in range(var.instance_count) : random_password.jupyter_token[idx].result]
  sensitive   = true
}
