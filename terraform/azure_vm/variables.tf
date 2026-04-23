variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "number_of_vms" {
  description = "Number of VMs to create"
  type        = number
  default     = 1
}

variable "location" {
  description = "Azure location"
  type        = string
  default     = "West US 2"
}
