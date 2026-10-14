output "resource_group_name" {
  description = "Resource group holding the PoC."
  value       = local.resource_group_name
}

output "location" {
  description = "Azure region of the deployment."
  value       = local.location
}

output "gateway_public_ip" {
  description = "Public IP of the Leostream Gateway. This changes every time the public IP is destroyed and recreated."
  value       = azurerm_public_ip.gateway.ip_address
}

output "broker_private_ip" {
  description = "Private IP of the Leostream Broker. It has no public IP by design."
  value       = var.broker_private_ip
}

output "nat_gateway_public_ip" {
  description = "Outbound address used by the Broker, or null when the NAT gateway is disabled."
  value       = var.nat_gateway_enabled ? azurerm_public_ip.nat[0].ip_address : null
}

output "broker_identity_principal_id" {
  description = "Object ID of the Broker's system-assigned managed identity. Grant this a role to let the Broker control Azure VMs."
  value       = azurerm_linux_virtual_machine.broker.identity[0].principal_id
}

output "ssh_to_gateway" {
  description = "Command to open an administrative session on the Gateway."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.gateway.ip_address}"
}

output "ssh_to_broker" {
  description = "Command to reach the Broker, which is only accessible through the Gateway."
  value       = "ssh -J ${var.admin_username}@${azurerm_public_ip.gateway.ip_address} ${var.admin_username}@${var.broker_private_ip}"
}

output "broker_admin_url" {
  description = "Broker administrator interface, published through the Gateway. Null when broker_admin_port is disabled, in which case use broker_admin_tunnel."
  value       = var.broker_admin_port == null ? null : "https://${azurerm_public_ip.gateway.ip_address}:${var.broker_admin_port}/"
}

output "broker_admin_tunnel" {
  description = "Open an SSH tunnel, then browse to https://localhost:8443/ for the Broker admin interface."
  value       = "ssh -N -L 8443:${var.broker_private_ip}:443 ${var.admin_username}@${azurerm_public_ip.gateway.ip_address}"
}

output "grant_broker_role_command" {
  description = "Role assignment an administrator must run before the Broker can enumerate Azure VMs."
  value       = "az role assignment create --assignee-object-id ${azurerm_linux_virtual_machine.broker.identity[0].principal_id} --assignee-principal-type ServicePrincipal --role Contributor --scope /subscriptions/<subscription-id>/resourceGroups/${local.resource_group_name}"
}
