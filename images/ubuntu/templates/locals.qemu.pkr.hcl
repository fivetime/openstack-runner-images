locals {
  # Ubuntu release codename per target OS, used to build the cloud image URL.
  qemu_codename_map = {
    "ubuntu22" = "jammy"
    "ubuntu24" = "noble"
    "ubuntu26" = "resolute"
  }

  qemu_codename = lookup(local.qemu_codename_map, var.image_os, "")

  qemu_source_image_url = coalesce(
    var.qemu_source_image_url,
    local.qemu_codename != ""
    ? "https://cloud-images.ubuntu.com/${local.qemu_codename}/current/${local.qemu_codename}-server-cloudimg-amd64.img"
    : ""
  )
}
