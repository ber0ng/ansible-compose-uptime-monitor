variable "subscription_id" {
  description = "The subscription ID for the Azure provider."
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westus3"
}

variable "prefix" {
  description = "Name prefix for all resources"
  type        = string
  default     = "pulsecheck"
}

variable "vm_size" {
  description = "VM size"
  type        = string
  default     = "Standard_B2s_v2"
}

variable "admin_username" {
  description = "Admin username for the VM"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block for allowed SSH access"
  type        = string
}

variable "auto_shutdown_time" {
  description = "Auto shutdown time for the VM in HH:MM format (UTC)"
  type        = string
  default     = "2300"
}

variable "auto_shutdown_timezone" {
  description = "Timezone for auto shutdown"
  type        = string
  default     = "Singapore Standard Time"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
