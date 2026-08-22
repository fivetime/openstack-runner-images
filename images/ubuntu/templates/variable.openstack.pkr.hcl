# OpenStack-specific variables.
#
# Authentication is NOT declared here on purpose: the Packer OpenStack builder
# reads the standard OS_* environment variables (or OS_CLOUD + clouds.yaml)
# automatically. Source your openrc / application credential before building.

variable "os_flavor" {
  type        = string
  description = "Nova flavor used for the build VM. Needs >= 75 GiB disk and >= 8 GiB RAM."
  default     = "${env("PKR_OS_FLAVOR")}"
}

variable "os_network" {
  type        = string
  description = "Neutron network UUID the build VM is attached to."
  default     = "${env("PKR_OS_NETWORK")}"
}

variable "os_floating_ip_network" {
  type        = string
  description = "Network to allocate a floating IP from. Leave empty when Packer can reach the VM directly."
  default     = "${env("PKR_OS_FLOATING_IP_NETWORK")}"
}

variable "os_security_groups" {
  type        = list(string)
  description = "Security groups applied to the build VM. Must allow inbound SSH from the Packer host."
  default     = []
}

variable "os_source_image_name" {
  type        = string
  description = "Base Ubuntu cloud image in Glance. Empty = pick by image_os (see locals.openstack.pkr.hcl)."
  default     = ""
}

variable "os_ssh_username" {
  type        = string
  description = "Default user of the Ubuntu cloud image."
  default     = "ubuntu"
}

variable "os_volume_size" {
  type        = number
  description = "Boot-from-volume size in GiB. 0 = boot from the flavor's ephemeral disk instead."
  default     = 0
}

variable "os_image_visibility" {
  type        = string
  description = "Visibility of the produced Glance image."
  default     = "private"
}
