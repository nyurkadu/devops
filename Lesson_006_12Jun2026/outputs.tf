output "vm_public_ips" {
  description = "Публичные IP-адреса созданных виртуальных машин"
  value       = {
    for idx, vm in azurerm_linux_virtual_machine.vm : vm.name => azurerm_public_ip.pip[idx].ip_address
  }
}

output "vm_names" {
  value = [for vm in azurerm_linux_virtual_machine.vm: vm.name]
}