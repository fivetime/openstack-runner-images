locals {
  # Base cloud image per target OS. Override with var.os_source_image_name.
  openstack_source_image_map = {
    "ubuntu22" = "ubuntu-22.04-server-cloudimg-amd64"
    "ubuntu24" = "ubuntu-24.04-server-cloudimg-amd64"
    "ubuntu26" = "ubuntu-26.04-server-cloudimg-amd64"
  }

  openstack_source_image_name = coalesce(
    var.os_source_image_name,
    lookup(local.openstack_source_image_map, var.image_os, "")
  )

  # Reuse the same name Azure builds produce so downstream tooling matches.
  openstack_image_name = var.managed_image_name != "" ? var.managed_image_name : "packer-${var.image_os}-${var.image_version}"
}
