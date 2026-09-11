#!/bin/bash -e
################################################################################
##  File:  install-raas-runner.sh
##  Desc:  把 runner 用户与 actions-runner 二进制烘进镜像(RaaS 专用)
################################################################################
#
# 为什么要烘进来:这两件事原本在开机时由 cloud-init 做,实测(cloud-init
# analyze blame)各花:
#
#     31.868s  config-users_groups    创建 runner 用户
#     25.232s  config-scripts_user    下载并解压 actions-runner
#
# 合计 57 秒,占 96 秒开机时间的一多半。
#
# 用户那 32 秒的来源不明显:本镜像的 /etc/skel 有 799 MB / 915 个文件
# (上游 runner-images 把工具链放在那里),`useradd -m` 每次开机都要整份拷贝。
# 在构建时做一次,开机就完全不用做。

RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_VERSION="${RUNNER_VERSION:?RUNNER_VERSION is required}"
RUNNER_HOME="/home/${RUNNER_USER}"
ARCH="${RUNNER_ARCH:-x64}"

# docker 组必须在这里就加上。cloud-init 的 users_groups 模块发现用户已存在
# 会【整个跳过】,不会补加组 —— 少了它,workflow 里的 docker 命令会以
# "permission denied ... /var/run/docker.sock" 失败。
useradd --create-home --shell /bin/bash --groups docker,sudo "${RUNNER_USER}"
passwd --lock "${RUNNER_USER}"
echo "${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${RUNNER_USER}"
chmod 0440 "/etc/sudoers.d/90-${RUNNER_USER}"

url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz"
install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" "${RUNNER_HOME}/actions-runner"
curl -fsSL --retry 5 --retry-delay 3 -o /tmp/actions-runner.tar.gz "${url}"
tar xzf /tmp/actions-runner.tar.gz -C "${RUNNER_HOME}/actions-runner"
rm -f /tmp/actions-runner.tar.gz
chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_HOME}/actions-runner"

# 记下烘进来的版本,供开机时判断是否要覆盖(见 RaaS 的 cloud-init 模板)。
echo "${RUNNER_VERSION}" > "${RUNNER_HOME}/actions-runner/.baked-version"
chown "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_HOME}/actions-runner/.baked-version"

# Give the runner user a systemd user session at boot (rootless podman socket,
# systemctl --user). This is exactly what `loginctl enable-linger` writes; writing
# it here does not need logind to be running inside the build VM. The pool's
# cloud-init still enables linger and waits for the session bus, because a spec
# can point at an older image without this file (openstack-raas doc/machine-config.md).
install -d -m 0755 /var/lib/systemd/linger
touch "/var/lib/systemd/linger/${RUNNER_USER}"

# 自检:装错了要在构建时就失败,而不是等到租户的作业开不起来。
test -x "${RUNNER_HOME}/actions-runner/run.sh"
id -nG "${RUNNER_USER}" | tr ' ' '\n' | grep -qx docker
test -f "/var/lib/systemd/linger/${RUNNER_USER}"
echo "raas: baked ${RUNNER_USER} + actions-runner ${RUNNER_VERSION}"
