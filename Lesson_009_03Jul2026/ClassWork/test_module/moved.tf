moved {
  from = azurerm_virtual_network.vnet
  to   = module.network.azurerm_virtual_network.vnet
}

moved {
  from = azurerm_subnet.subnet
  to   = module.network.azurerm_subnet.subnet
}

moved {
  from = azurerm_network_security_group.nsg
  to   = module.network.azurerm_network_security_group.nsg
}

moved {
  from = azurerm_network_security_rule.ssh
  to   = module.network.azurerm_network_security_rule.ssh
}

moved {
  from = azurerm_public_ip.vm_ip
  to   = module.network.azurerm_public_ip.vm_ip
}

moved {
  from = azurerm_network_interface.nic
  to   = module.network.azurerm_network_interface.nic
}

moved {
  from = azurerm_subnet_network_security_group_association.subnet_nsg
  to   = module.network.azurerm_subnet_network_security_group_association.subnet_nsg
}