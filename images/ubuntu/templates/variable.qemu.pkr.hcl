# QEMU-specific variables.
#
# The qemu source builds the image locally on any host with KVM and internet
# access, producing a qcow2 that can then be uploaded to Glance (or anywhere
# else). It does not depend on OpenStack networking being reachable, which is
# why it exists alongside the openstack source.

variable "qemu_source_image_url" {
  type        = string
  description = "Base Ubuntu cloud image (URL or local path). Empty = derive from image_os."
  default     = ""
}

variable "qemu_source_image_checksum" {
  type        = string
  description = "Checksum of the base image, e.g. 'sha256:abc...' or 'none' to skip."
  default     = "none"
}

variable "qemu_cpus" {
  type        = number
  description = "vCPUs given to the build VM."
  default     = 8
}

variable "qemu_memory" {
  type        = number
  description = "RAM in MiB given to the build VM."
  default     = 16384
}

variable "qemu_output_dir" {
  type        = string
  description = "Directory the qcow2 is written to. Must not already exist."
  default     = "output-qemu"
}

variable "qemu_ssh_private_key_file" {
  type        = string
  description = "Private key Packer uses to SSH into the build VM."
  default     = ""
}

variable "qemu_ssh_public_key" {
  type        = string
  description = "Matching public key, injected via the cloud-init NoCloud seed."
  default     = ""
}

variable "qemu_accelerator" {
  type        = string
  description = "kvm, hvf, or none. 'none' is emulation only and far too slow for this build."
  default     = "kvm"
}
