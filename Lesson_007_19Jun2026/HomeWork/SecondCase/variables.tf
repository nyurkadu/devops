variable "admin_username" {
  description = "Admin username for the Linux VM"
  type        = string
  default     = "azureuser"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "nic_name" {
  description = "Network Interface name"
  type        = string
  default     = "nic-tf-fileprov"
}

variable "nsg_name" {
  description = "Network Security Group name"
  type        = string
  default     = "nsg-tf-fileprov"
}

variable "public_ip_name" {
  description = "Public IP name"
  type        = string
  default     = "pip-tf-fileprov"
}

variable "resource_group_name" {
  description = "Resource Group name"
  type        = string
  default     = "Avi_test_rg"
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key"
  type        = string
  default     = "C:/Users/avila/.ssh/id_rsa"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
  default     = "C:/Users/avila/.ssh/id_rsa.pub"
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
  default     = "7a016bad-eb8a-41c2-acc2-af1d1d8ee11f"
}


variable "subnet_address_prefix" {
  description = "Subnet CIDR"
  type        = string
  default     = "10.10.1.0/24"
}

variable "subnet_name" {
  description = "Subnet name"
  type        = string
  default     = "subnet-web"
}

variable "vm_name" {
  description = "Virtual Machine name"
  type        = string
  default     = "vm-tf-fileprov"
}

variable "vm_size" {
  description = "Azure VM size"
  type        = string
  default     = "Standard_B1s"
}

variable "vnet_address_space" {
  description = "VNet CIDR"
  type        = string
  default     = "10.10.0.0/16"
}

variable "vnet_name" {
  description = "Virtual Network name"
  type        = string
  default     = "vnet-tf-fileprov"
}