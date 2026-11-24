# Terraform
terraform {
  required_version = ">= 1.6"
}

variable "name" {
  type    = string
  default = "glimt"
}

output "greeting" {
  value = "Hej ${var.name}"
}
