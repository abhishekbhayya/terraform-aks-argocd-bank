variable "environment" {
  description = "Environment configuration to deploy: dev, test, or prod."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be dev, test, or prod."
  }
}

variable "resource_group_name" {
  description = "Azure resource group for the selected environment."
  type        = string
}

variable "location" {
  description = "Azure region for the resources."
  type        = string
  default     = "Japan East"
}

variable "keyvault_name_prefix" {
  description = "Lowercase alphanumeric prefix; a random suffix is appended."
  type        = string
  default     = "secret"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,17}$", var.keyvault_name_prefix))
    error_message = "keyvault_name_prefix must be 3-18 lowercase alphanumeric characters and start with a letter."
  }
}

variable "cluster_name_prefix" {
  type    = string
  default = "paas"
}

variable "dns_prefix" {
  type    = string
  default = "aks-paas"
}

variable "acr_name" {
  description = "Globally unique ACR name. Keep in sync with import-bank-of-anthos-images.ps1."
  type        = string
  default     = "abhishekregis734"
}

variable "argocd_public_ip_name" {
  type    = string
  default = "pip-argocd"
}

variable "availability_zones" {
  description = "Optional availability zones, for example [\"1\", \"2\"]. Leave empty if the selected SKU has zonal capacity issues."
  type        = list(string)
  default     = []
}
