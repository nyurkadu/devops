output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.rg.name
}

output "vm_id" {
  description = "ID of the Linux virtual machine"
  value       = azurerm_linux_virtual_machine.vm.id
}

output "vm_name" {
  description = "Name of the Linux virtual machine"
  value       = azurerm_linux_virtual_machine.vm.name
}

output "vnet_id" {
  description = "ID of the virtual network"
  value       = module.network.vnet_id
}

output "subnet_id" {
  description = "ID of the subnet"
  value       = module.network.subnet_id
}

output "nic_id" {
  description = "ID of the network interface"
  value       = module.network.nic_id
}

output "nsg_id" {
  description = "ID of the network security group"
  value       = module.network.nsg_id
}

output "public_ip_address" {
  description = "Public IP address assigned to the VM"
  value       = module.network.public_ip_address
}