output "workspace_info" {
  value = "workspace_name=${terraform.workspace}\nworkgroup_name=${var.workgroup_name}"
}

output "configured_workspaces" {
  value = var.workspaces
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "storage_account_name" {
  value = azurerm_storage_account.sa.name
}
