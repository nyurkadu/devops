terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0" # или "~> 4.0" в зависимости от вашей версии Terraform
    }
  }
}

provider "azurerm" {
  features {} # Этот блок обязателен для работы провайдера azurerm
}
