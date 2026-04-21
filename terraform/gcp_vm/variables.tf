variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "number_of_vms" {
  description = "Number of VMs to create"
  type        = number
  default     = 1
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"
}
