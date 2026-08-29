#!/usr/bin/env bash
# 装 RaaS BuildKit 后端所需的东西(doc: openstack-raas 的
# images/buildkit/README.md 与 doc/buildkit-service.md §1.4)。
#
# 后端与 GitHub Actions runner **共用这个镜像**:Glance 是 raw + Nova
# images_type=rbd,开机是 COW 克隆,100 GiB 零复制 —— 2026-08-29 实测比 3.5 GiB
# 的云镜像还快 5 秒到 ACTIVE。自建一个最小镜像省下的是零,换来的是永远自己
# 维护一条流水线。
#
# ⚠️ **镜像里少什么,租户就悄悄少一项能力,而他会去怪自己的 Dockerfile。**
# 租户敲的 --platform / --output / --attest / RUN --mount 全是客户端开关,
# buildkitd 收到就执行 —— 我们只负责这台机器的环境不比一台普通笔记本窄。
#
# 两个二进制都当**普通容器镜像**从我们自己的 Harbor 取:buildkitd 走
# cache-dockerhub 代理缓存(上游自己的发布渠道,经我们的仓库),agent 是
# openstack-raas 用 `make agent-image` 推的。一套机制,不为其中任何一个另造
# 发布流水线,也不依赖 github.com —— BuildKit 那条产品线跟 GitHub 没有关系,
# 租户只是把 buildx 指向我们。
set -euo pipefail

BUILDKIT_IMAGE=${BUILDKIT_IMAGE:-harbor.tue.jp/cache-dockerhub/moby/buildkit:v0.27.0}
AGENT_IMAGE=${AGENT_IMAGE:?需要设 AGENT_IMAGE,例如 harbor.tue.jp/fivetime/raas-bkagent:<版本>}
DIST=$(mktemp -d)
trap 'rm -rf "$DIST"' EXIT

extract() {
    local image=$1 cid
    shift
    docker pull -q "$image" >/dev/null
    # 显式给一个命令:scratch 镜像若没有 ENTRYPOINT/CMD,docker create 会拒
    # (no command specified),而它只是建容器、并不执行。
    cid=$(docker create "$image" /nonexistent)
    for f in "$@"; do docker cp "$cid:$f" "$DIST/$(basename "$f")"; done
    docker rm -f "$cid" >/dev/null
}

# ⚠️ **buildkit-runc 必须一起取。** buildkitd 要它来跑构建容器。
# 2026-08-29 第一轮真机验证里只装了 buildkitd+buildctl 却照样能构建 —— 那是
# 因为 runner 镜像**自带 docker 的 runc**。别指望那个:上游哪天换了基础镜像
# 或不再预装 docker,这条会在没有任何提示的情况下断掉,而症状是 buildkitd
# **起得来**、机器报 ready,每个租户构建失败。
extract "$BUILDKIT_IMAGE" /usr/bin/buildkitd /usr/bin/buildctl /usr/bin/buildkit-runc
extract "$AGENT_IMAGE" /usr/bin/raas-bkagent

install -m 0755 "$DIST/buildkitd"     /usr/local/bin/buildkitd
install -m 0755 "$DIST/buildctl"      /usr/local/bin/buildctl
install -m 0755 "$DIST/buildkit-runc" /usr/local/bin/buildkit-runc
install -m 0755 "$DIST/raas-bkagent"  /usr/local/bin/raas-bkagent
install -d -m 0755 /etc/raas
{
    echo "buildkit_image=$BUILDKIT_IMAGE"
    echo "agent_image=$AGENT_IMAGE"
    echo "built_at=$(date -u +%FT%TZ)"
} > /etc/raas/image-manifest
chmod 0644 /etc/raas/image-manifest

# buildkitd 找 runc 是按 PATH 里的 `buildkit-runc`,找不到再退回 `runc`。
# 最小镜像上没有 docker,也就没有 runc —— 这是 2026-08-29 真机验证没暴露的
# 一个坑:当时用的是 runner 镜像,自带 docker 的 runc,所以只装 buildkitd
# 也能构建。漏了它,buildkitd **起得来但每次构建都失败**。
/usr/local/bin/buildkit-runc --version

# buildkitd 的网络:不放 CNI 配置,`--oci-worker-net=auto` 就回落到 host
# (util/network/netproviders/network.go)。构建步骤因此共享宿主机的网络命名空间。
#
# ⚠️ 这意味着租户的 RUN 能到达这台机器能到达的任何地方。控制点是**安全组的
# 出向规则**,不是容器的网络命名空间 —— 别指望换成 bridge 就隔离了,bridge
# 的 NAT 一样出得去。
install -d -m 0755 /var/lib/buildkit

# cloud-init 会写 /etc/systemd/system/{raas-bkagent,buildkitd}.service(见
# internal/bkprovision/cloudinit.go),这里不预置 —— 单元里带着端口等参数,
# 预置一份会和 user-data 里那份不一致,而不一致的那个才是生效的。

systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true

# binfmt 处理器必须带 F(fix-binary)标志。
#
# 没有 F 的话,内核是在**进入容器的挂载命名空间之后**才去找解释器的 —— 而
# 那个 rootfs 里没有 qemu-aarch64-static,于是每个 arm64 的 RUN 都报
# "exec format error"。带 F 时解释器在注册那一刻就被打开并常驻,容器里
# 不需要有它。
#
# Ubuntu 的 qemu-user-static 通过 /usr/lib/binfmt.d/*.conf 交给
# systemd-binfmt 注册,开机自动生效 —— 这里只做启用与自检。
systemctl enable systemd-binfmt.service 2>/dev/null || true

apt-get update
# buildkitd 自己不需要前两个,但没有它们排障要 SSH 进去才发现缺:
#   e2fsprogs      —— agent 要 mkfs.ext4 格式化缓存卷
#   util-linux     —— blkid / mountpoint
#
# qemu-user-static + binfmt-support 是**跨架构构建的前提**。
# BuildKit 不只是打镜像,它是通用的 DAG 执行引擎,而 `--platform
# linux/arm64` 是租户最常用的能力之一(交叉编译、多架构 manifest)。
# 没有它 buildkitd 只报 linux/amd64 系列 —— 2026-08-29 实测,两个候选镜像
# (runner 与最小)**都不支持**,`buildx inspect` 的 Platforms 里一个非 x86
# 的都没有。
#
# ⚠️ 本集群 23 个节点全 amd64,没有 arm 硬件(§7.1)。所以 arm64 走的是
# **模拟**,慢一个数量级 —— 这不是架构缺口,是硬件缺口;接了 arm 计算节点
# 之后同一套代码按 flavor 配就行。
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    e2fsprogs util-linux ca-certificates \
    qemu-user-static binfmt-support
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "已安装:"
/usr/local/bin/buildkitd --version
/usr/local/bin/raas-bkagent --version
cat /etc/raas/image-manifest

# 自检:注册上了没有,以及有没有 F 标志。
# 放在构建期而不是开机期 —— 这里失败会让镜像构建红掉,而开机期失败只会让
# 某台机器悄悄少一半能力,租户看到的是"这个平台不支持"。
systemctl restart systemd-binfmt.service
for arch in aarch64 arm riscv64; do
    f=/proc/sys/fs/binfmt_misc/qemu-$arch
    [ -f "$f" ] || { echo "binfmt 没注册 $arch"; exit 1; }
    grep -q "^flags:.*F" "$f" || { echo "$arch 的 binfmt 没有 F 标志,容器里会 exec format error"; exit 1; }
done
echo "binfmt 已注册(带 F):$(ls /proc/sys/fs/binfmt_misc/ | grep -c qemu) 个架构"
