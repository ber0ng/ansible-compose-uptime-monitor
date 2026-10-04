variable "region" {
  type    = string
  default = "ap-southeast-2"
}

variable "project" {
  type    = string
  default = "pulsecheck"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "my_ip" {
  description = "Your Public IP"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Patht to the public key ansible will use"
  type        = string
}

variable "shutdown_cron" {
  description = "When to auto-stop the instance"
  type        = string
  default     = "cron(0 23 * * ? *)" # 11 pm everyday
}

