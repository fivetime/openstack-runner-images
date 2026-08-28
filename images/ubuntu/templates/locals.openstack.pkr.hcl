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

  # raas_os 的值,也是镜像名里的 OS 段。RaaS 的目录按镜像属性 raas_os
  # 匹配 flavor 的 raas:os,两边必须用同一个写法。
  openstack_os_label_map = {
    "ubuntu22" = "ubuntu-22.04"
    "ubuntu24" = "ubuntu-24.04"
    "ubuntu26" = "ubuntu-26.04"
  }
  openstack_os_label = lookup(local.openstack_os_label_map, var.image_os, var.image_os)

  # 命名规范:raas-runner-<os>-<版本>-<构建日期>.<序号>
  #
  # 曾经手工传 managed_image_name 建成 github-runner-*,而这个镜像**两条
  # 产品线共用** —— GitHub 的 agent 不在镜像里(开机时下载),镜像装的是
  # 工具链。租户在面板上看到自己的 GitLab 作业跑在 github-runner-* 上,
  # 合理的第一反应是配错了;排查时也会把人往错误的方向带。
  #
  # 前缀跟产品走,不跟某一个代码托管平台走。
  openstack_image_name = var.managed_image_name != "" ? var.managed_image_name : "raas-runner-${local.openstack_os_label}-${var.image_version}"
}
