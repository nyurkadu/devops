terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.workgroup_name}-${terraform.workspace}"
  location = var.location
  tags = {
    environment = terraform.workspace
    workgroup   = var.workgroup_name
  }
}

resource "azurerm_storage_account" "sa" {
  name                     = substr(lower(replace("sa${replace(var.workgroup_name, "_", "")}${terraform.workspace}", "-", "")), 0, 24)
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = terraform.workspace
    workgroup   = var.workgroup_name
  }
}
