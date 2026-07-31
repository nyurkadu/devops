# az login `
#   --username "testuser3@antonborisovdoitplayground.onmicrosoft.com" `
#   --password "Banalinet4"


# 1. Required Providers Configuration
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

# 2. Azure Provider Settings
provider "azurerm" {
  features {}
}

# 3. Random Pet Generator
resource "random_pet" "my_pet" {
  length    = 2
  separator = ""
}

# 4. Local File Resource
resource "local_file" "pet_info" {
  filename = "${path.module}/${random_pet.my_pet.id}.txt"
  content  = "The generated pet name is: ${random_pet.my_pet.id}"
}

# 5. Azure Resource Group
resource "azurerm_resource_group" "my_rg" {
  name     = "rg-${random_pet.my_pet.id}"
  location = "West Europe"
  
  # Added tag here
  tags = {
    owner = "Avi"
  }
}

# 6. Azure Storage Account
resource "azurerm_storage_account" "my_storage" {
  name                     = "st${random_pet.my_pet.id}" 
  resource_group_name      = azurerm_resource_group.my_rg.name
  location                 = azurerm_resource_group.my_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # Added tag here - This satisfies the Azure Policy
  tags = {
    owner = "Avi"
  }
}

# 7. Outputs
output "pet_name_generated" {
  value = random_pet.my_pet.id
}

output "storage_account_name" {
  value = azurerm_storage_account.my_storage.name
}


