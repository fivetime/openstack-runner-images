packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "image" {
  # Base cloud image is used directly as the disk, then grown to the size the
  # Azure path uses (locals.ubuntu.pkr.hcl).
  iso_url        = local.qemu_source_image_url
  iso_checksum   = var.qemu_source_image_checksum
  disk_image     = true
  disk_size      = "${local.os_disk_size_gb}G"
  disk_interface = var.qemu_disk_interface
  format         = "qcow2"

  accelerator = var.qemu_accelerator
  cpus        = var.qemu_cpus

  # Without this QEMU presents the qemu64 model, which lacks SSSE3; the
  # Homebrew installer then aborts the whole build.
  qemuargs = [["-cpu", var.qemu_cpu_model]]

  memory     = var.qemu_memory
  net_device = "virtio-net"
  headless   = true

  # Default user-mode networking gives the guest outbound NAT through the host,
  # so the build does not depend on any lab network being reachable.

  # cloud-init NoCloud seed: injects the key Packer will SSH in with.
  cd_label = "cidata"
  cd_content = {
    "meta-data" = <<-EOT
      instance-id: ${local.openstack_image_name}
      local-hostname: packer-build
    EOT
    "user-data" = <<-EOT
      #cloud-config
      ssh_pwauth: false
      users:
        - name: ${var.os_ssh_username}
          sudo: "ALL=(ALL) NOPASSWD:ALL"
          shell: /bin/bash
          lock_passwd: true
          ssh_authorized_keys:
            - ${var.qemu_ssh_public_key}
    EOT
  }

  ssh_username         = var.os_ssh_username
  ssh_private_key_file = var.qemu_ssh_private_key_file
  ssh_timeout          = "30m"

  shutdown_command = "sudo shutdown -P now"
  shutdown_timeout = "15m"

  output_directory = var.qemu_output_dir
  vm_name          = "${local.openstack_image_name}.qcow2"
}
