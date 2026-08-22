packer {
  required_plugins {
    openstack = {
      version = ">= 1.1.2"
      source  = "github.com/hashicorp/openstack"
    }
  }
}

source "openstack" "image" {
  # Credentials come from OS_* env vars / OS_CLOUD, handled by the plugin.
  source_image_name   = local.openstack_source_image_name
  flavor              = var.os_flavor
  networks            = [var.os_network]
  floating_ip_network = var.os_floating_ip_network
  security_groups     = var.os_security_groups

  image_name       = local.openstack_image_name
  image_visibility = var.os_image_visibility

  # The build needs the same disk size the Azure path uses (locals.ubuntu.pkr.hcl).
  # With volume_size > 0 Packer boots from a Cinder volume of that size;
  # otherwise the flavor's disk must already be >= local.os_disk_size_gb.
  use_blockstorage_volume = var.os_volume_size > 0
  volume_size             = var.os_volume_size > 0 ? var.os_volume_size : null

  ssh_username   = var.os_ssh_username
  ssh_ip_version = "4"
  ssh_timeout    = "30m"

  # Ubuntu cloud images grow the rootfs on first boot; give cloud-init time.
  ssh_handshake_attempts = 100
}
