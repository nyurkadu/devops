# terraform {
#   required_providers {
#     azurerm = {
#       source  = "hashicorp/azurerm"
#       version = "~> 3.0"
#     }
#     random = {
#       source  = "hashicorp/random"
#       version = "~> 3.0"
#     }
#     local = {
#       source  = "hashicorp/local"
#       version = "~> 2.0"
#     }
#   }
# }

# # Provider block (ensure only one exists in your directory)
# provider "azurerm" {
#   features {}
# }

# Reads the name from your local text file
data "local_file" "local_file" {
  filename = "${path.module}/my_data.txt"
}

# Creates the Resource Group
resource "azurerm_resource_group" "example" {
  name     = trimspace(data.local_file.local_file.content)
  location = "East US"

  tags = {
    environment = "dev12"
    created_by  = "terraform12"
    source      = "local_file_script12"
  }

  lifecycle {
    # This prevents Terraform from overwriting manual changes to tags
    ignore_changes = [
      tags,
      name,
    ]
  }
}

# Displays the final name in the console
output "resource_group_name" {
  value = azurerm_resource_group.example.name
}
