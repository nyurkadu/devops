variable "resource_group_name" {
  type        = string
  default     = "student-rg"
  description = "Имя группы ресурсов"
}

variable "location" {
  type        = string
  default     = "westeurope"
  description = "Регион развертывания"
}

variable "admin_username" {
  type        = string
  default     = "azureuser"
  description = "Имя пользователя для ВМ"
}

variable "admin_password" {
  type        = string
  default     = "ComplexPassword123!"
  sensitive   = true
  description = "Пароль администратора"
}
