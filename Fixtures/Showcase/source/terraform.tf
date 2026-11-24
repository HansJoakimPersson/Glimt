terraform {
  required_version = ">= 1.6"
}

variable "region" {
  type        = string
  description = "Deployment region"
  default     = "eu-north-1"
}

locals {
  labels = {
    application = "glimt"
    managed     = true
  }
}

resource "example_service" "preview" {
  name   = "preview-service"
  region = var.region
  tags   = local.labels
}
