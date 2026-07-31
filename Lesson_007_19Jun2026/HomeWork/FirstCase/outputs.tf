output "detected_my_public_ip_cidr" {
  description = "Detected current public IP in CIDR notation used in NSG SSH rule"
  value       = local.my_public_ip
}

output "network_security_group_name" {
  description = "Network Security Group name"
  value       = azurerm_network_security_group.nsg.name
}

output "public_ip_address" {
  description = "Public IP address of the VM"
  value       = azurerm_public_ip.pip.ip_address
}

output "resource_group_name" {
  description = "Resource Group name"
  value       = azurerm_resource_group.rg.name
}

output "ssh_connection" {
  description = "SSH command to connect to the VM"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.pip.ip_address}"
}

output "subnet_name" {
  description = "Subnet name"
  value       = azurerm_subnet.subnet.name
}

output "virtual_network_name" {
  description = "Virtual Network name"
  value       = azurerm_virtual_network.vnet.name
}

output "vm_name" {
  description = "Virtual machine name"
  value       = azurerm_linux_virtual_machine.vm.name
}

output "web_url" {
  description = "URL for checking Nginx in browser"
  value       = "http://${azurerm_public_ip.pip.ip_address}"
}