variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "number_of_vms" {
  description = "Number of VMs to create"
  type        = number
  default     = 1
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "gcp_project_id" {
  description = "GCP Project ID for Workload Identity Federation"
  type        = string
}
