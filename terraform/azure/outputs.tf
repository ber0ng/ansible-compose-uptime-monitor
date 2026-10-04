output "public_ip" {
  description = "Public IP"
  value       = azurerm_public_ip.public_ip.ip_address
}

output "admin_username" {
  value = var.admin_username
}

output "ssh_command" {
  description = "Copy paste to ssh in"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.public_ip.ip_address}"
}
