variable "workspaces" {
  description = "List of Terraform workspaces"
  type        = list(string)
  default     = ["dev", "qa", "prod"]
}

variable "workgroup_name" {
  description = "Workgroup name used in outputs"
  type        = string
  default     = "avi_ws_gr"
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
  default     = "7a016bad-eb8a-41c2-acc2-af1d1d8ee11f"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}
