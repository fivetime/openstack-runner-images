#!/usr/bin/env bash
# 给刚构建出的镜像打上 RaaS 需要的属性。
#
# **必须跑,而且必须由脚本跑。** packer 的 openstack builder(v1.1.4)设不了
# 镜像属性 —— image_metadata / image_properties 这两个名字它都不认,只接受
# image_tags,而 Glance 的 tag 不是 property。所以属性只能在构建之后打。
#
# 靠人记得的后果已经发生过:2026-08-23 构建的 ubuntu-26.04 镜像没有 raas_os,
# 于是它对目录**完全不可见** —— 没有报错、没有告警,只是那个 OS 永远开不出
# 机器。同一批的 24.04 有,因为那次记得了。
#
# 两个属性各自的作用:
#   raas_os          目录用它把镜像匹配到 flavor 的 raas:os。缺了=镜像不存在。
#   hypervisor_type  缺了会被调度到 Incus 节点,报 "Bad image format"。
set -euo pipefail

usage() { echo "用法: $0 <镜像名或ID> <raas_os,如 ubuntu-24.04>" >&2; exit 2; }
[ $# -eq 2 ] || usage
IMAGE=$1
RAAS_OS=$2

openstack image set \
    --property raas_os="${RAAS_OS}" \
    --property hypervisor_type=qemu \
    "${IMAGE}"

# 核实,而不是相信 set 的退出码:属性名打错时它照样成功,
# 只是打上了一个没人读的属性。
got=$(openstack image show "${IMAGE}" -f json \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["properties"].get("raas_os",""))')
if [ "${got}" != "${RAAS_OS}" ]; then
    echo "raas_os 没有落上:读回来是 '${got}',期望 '${RAAS_OS}'" >&2
    exit 1
fi
echo "ok: ${IMAGE} raas_os=${RAAS_OS} hypervisor_type=qemu"
