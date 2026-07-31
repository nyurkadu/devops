output "subnet_id" {
  value = azurerm_subnet.subnet.id
}

output "nic_id" {
  value = azurerm_network_interface.nic.id
}

output "public_ip_id" {
  value = azurerm_public_ip.vm_ip.id
}

output "public_ip_address" {
  value = azurerm_public_ip.vm_ip.ip_address
}

output "vnet_id" {
  value = azurerm_virtual_network.vnet.id
}

output "nsg_id" {
  value = azurerm_network_security_group.nsg.id
}