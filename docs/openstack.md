# Building runner images on OpenStack

Upstream `actions/runner-images` only ships an `azure-arm` Packer source.
This fork adds an `openstack` source alongside it, so the same provisioner
pipeline (and therefore the same installed toolset) can produce Glance images.

The Azure path is untouched — both sources live in the same `build` block and
are selected with `packer build -only=...`.

## What was added

| File | Purpose |
|---|---|
| `images/ubuntu/templates/source.openstack.pkr.hcl` | The `openstack` source + `required_plugins` |
| `images/ubuntu/templates/variable.openstack.pkr.hcl` | `os_*` variables (flavor, network, floating IP, …) |
| `images/ubuntu/templates/locals.openstack.pkr.hcl` | Maps `image_os` → base Glance image name |

Two upstream files carry a minimal patch:

- `images/ubuntu/templates/build.ubuntu-{24,26}_04.pkr.hcl`
  — added `source.openstack.image` to `sources`, gated the Azure `waagent`
  deprovision step with `only = ["azure-arm.image"]`, and added an
  OpenStack deprovision step (`cloud-init clean`, drop SSH host keys and
  machine-id).
- `images/ubuntu/scripts/build/configure-environment.sh`
  — the `/etc/waagent.conf` edits are now wrapped in a file-exists check.
  The script runs with `bash -e`, so on a non-Azure image the unguarded
  `sed -i` aborted the build.

Everything else is upstream, unmodified. Keeping the diff to new files plus
three small hunks is deliberate: `gh repo sync` / `git merge upstream/main`
stays cheap.

## Prerequisites

**Base images in Glance.** Upload the stock Ubuntu cloud images:

```bash
for rel in noble:24.04 resolute:26.04; do
  code=${rel%%:*}; ver=${rel##*:}
  curl -sSO "https://cloud-images.ubuntu.com/${code}/current/${code}-server-cloudimg-amd64.img"
  # verify against https://cloud-images.ubuntu.com/${code}/current/SHA256SUMS
  openstack image create --disk-format qcow2 --container-format bare \
    --file "${code}-server-cloudimg-amd64.img" \
    --property os_distro=ubuntu --property os_version="${ver}" \
    --property architecture=x86_64 --public \
    "ubuntu-${ver}-server-cloudimg-amd64"
done
```

The names must match `locals.openstack.pkr.hcl`, or pass
`-var os_source_image_name=...`.

> Note: 26.04's codename is `resolute`.

**A flavor with enough disk.** The Azure path uses `os_disk_size_gb = 75`
(`locals.ubuntu.pkr.hcl`). Either use a flavor whose disk is >= 75 GiB, or set
`-var os_volume_size=75` to boot the build VM from a Cinder volume instead.
The build also wants >= 8 GiB RAM and several vCPUs — the toolset install is
long and largely CPU bound.

**Network reachability.** Packer SSHes into the build VM. Either run Packer on
a host that can route to `os_network` directly, or set
`os_floating_ip_network` so Packer allocates a floating IP. The security group
must allow inbound TCP/22 from the Packer host.

**Packer plugins.**

```bash
cd images/ubuntu/templates
packer init .
```

## Build

Authentication uses the standard OpenStack environment — source your openrc or
export `OS_CLOUD`. No credentials are declared in the templates.

```bash
cd images/ubuntu/templates

packer build \
  -only='ubuntu-24_04.openstack.image' \
  -var 'image_os=ubuntu24' \
  -var "image_version=$(date -u +%Y%m%d).1" \
  -var 'os_flavor=<flavor>' \
  -var 'os_network=<neutron-network-uuid>' \
  -var 'os_floating_ip_network=<external-network>' \
  -var 'os_volume_size=0' \
  .
```

> **`os_volume_size=0` 不是笔误。** 大于 0 时 packer 从 Cinder 卷启动,出镜像走
> `volume upload-to-image`,而那条路用 chunked 编码上传 —— Glance 跑在 uWSGI 下
> 默认收不了,构建会在最后一步失败,报
> `Error waiting for image: Resource not found`(Glance 返回 500,调用方随即把
> 镜像删掉,packer 轮询只剩 404)。修法见 OpenStack-Helm-Deploy.md 里
> `${OVERRIDES_DIR}/glance/conf.yaml` 的 `glance_api_uwsgi` 段。
>
> 取 0 则改用 flavor 自带的本地盘,出镜像走 Nova 的 createImage,不经 Cinder。
> 前提是 **flavor 的 disk 必须 ≥ 镜像所需**(本集群 `ci-build-8` 是 100 GiB,
> 镜像 75 GiB)。

For 26.04 use `-only='ubuntu-26_04.openstack.image' -var 'image_os=ubuntu26'`.

The resulting Glance image is named `raas-runner-<os>-<image_version>`
(e.g. `raas-runner-ubuntu-24.04-20260824.1`) unless `-var managed_image_name=...`
is given. 前缀跟产品走而不跟平台走:这个镜像**两条产品线共用** —— GitHub 的
agent 不在镜像里(开机时下载),镜像装的是工具链。

## 构建之后必须跑的一步

```bash
./finalize-openstack-image.sh raas-runner-ubuntu-24.04-$(date -u +%Y%m%d).1 ubuntu-24.04
```

**不能省,也不要手工敲。** packer 的 openstack builder(v1.1.4)设不了镜像属性
——`image_metadata` / `image_properties` 两个名字它都不认,只接受 `image_tags`,
而 Glance 的 tag 不是 property。所以属性只能在构建后打。

靠人记得的后果已经发生过:2026-08-23 构建的 ubuntu-26.04 镜像没有 `raas_os`,
于是它对 RaaS 的目录**完全不可见** —— 没有报错、没有告警,只是那个 OS 永远
开不出机器。同一批的 24.04 有,因为那次记得了。

## Validating without building

```bash
packer validate -only='ubuntu-24_04.openstack.image' \
  -var 'image_os=ubuntu24' -var 'image_version=test' \
  -var 'os_flavor=x' -var 'os_network=x' .
```

## Building locally with QEMU instead

If the OpenStack network cannot reach the internet (or Packer cannot reach the
build VM), the same pipeline can run on any host with KVM and outbound
connectivity, producing a qcow2 you upload to Glance afterwards.

Added for this: `source.qemu.pkr.hcl`, `variable.qemu.pkr.hcl`,
`locals.qemu.pkr.hcl`. The qemu source uses the default user-mode networking,
so the guest gets outbound NAT through the build host and no lab network needs
to be reachable. The cloud-init NoCloud seed (`cd_label = "cidata"`) injects
the SSH key Packer connects with.

```bash
ssh-keygen -t ed25519 -N '' -f ./packer-build

cd images/ubuntu/templates
packer init .
packer build \
  -only='ubuntu-24_04.qemu.image' \
  -var 'image_os=ubuntu24' \
  -var "image_version=$(date -u +%Y%m%d).1" \
  -var "qemu_ssh_private_key_file=$PWD/../../../packer-build" \
  -var "qemu_ssh_public_key=$(cat ../../../packer-build.pub)" \
  -var 'qemu_cpus=16' -var 'qemu_memory=32768' \
  -var 'qemu_output_dir=/data/packer-out/ubuntu24' \
  .
```

The base cloud image is fetched automatically from
`cloud-images.ubuntu.com/<codename>/current/` based on `image_os`
(22.04 = jammy, 24.04 = noble, 26.04 = resolute). Override with
`qemu_source_image_url` / `qemu_source_image_checksum`.

Upload the result:

```bash
openstack image create --disk-format qcow2 --container-format bare \
  --file /data/packer-out/ubuntu24/packer-ubuntu24-<version>.qcow2 \
  --property hypervisor_type=qemu \
  --property os_distro=ubuntu --property os_version=24.04 \
  packer-ubuntu24-<version>
```

> `hypervisor_type=qemu` matters if the cloud also has non-libvirt compute
> nodes (e.g. Incus/LXD). Without it the scheduler may place the instance on a
> host that cannot read a qcow2 VM image and the build aborts with
> `Image ... is unacceptable: Bad image format`.

## Known gaps

- **arm64 is not wired up.** `build.ubuntu-*-arm64.pkr.hcl` still only has the
  Azure source.
- **Swap.** On Azure the image relies on waagent to build a swap file from the
  resource disk. That does not exist on OpenStack; configure swap in the
  runner's cloud-init instead.
- **The software report step runs `pwsh`** and downloads
  `Ubuntu2404-Readme.md` / `software-report.json` back into the repo. That is
  upstream behaviour and applies to both platforms.

## Ubuntu 26.04 的四个坑(2026-09-11,raas-runner-ubuntu-26.04-20260911.1)

**1. `qemu-user-static` 在 26.04 上只是虚拟包。** 26.04 的 qemu-user 是静态编译的(`static-pie`),binfmt
注册由 `qemu-user-binfmt` 完成(标志 `OPF`,带 F);`qemu-user-static` 只是它 `Provides` 的名字,apt 不替你挑,
报 `has no installation candidate` 退出码 100。`install-raas-buildkit.sh` 现在按"是不是实体包"选:24.04 装
`qemu-user-static`,26.04 装 `qemu-user-binfmt`。这一步排在构建末尾,当天第一次失败发生在跑了 1 小时 46 分之后。

**2. 底图用 `current/` 且 checksum 为 `none` 时,packer 会悄悄复用缓存里的旧底图。** 缓存按 URL 键,`current/`
这个 URL 永远不变。要么钉带日期的版本目录并给 SHA256:

```bash
-var "qemu_source_image_url=https://cloud-images.ubuntu.com/resolute/20260823/resolute-server-cloudimg-amd64.img" \
-var "qemu_source_image_checksum=sha256:<该目录 SHA256SUMS 里的值>"
```

要么构建前删掉 `~/.cache/packer` 里对应的文件。

**3. 模板里新加的 RaaS 脚本,先在目标 OS 的一次性 VM 上单独跑一遍。** RaaS 的几步都在工具链装完之后,完整构建
要近两小时才跑到。用上一版同 OS 的镜像起一台 VM(`--config-drive true`,不依赖元数据服务),把脚本拉进去单独执行,
十几分钟就能暴露包名、路径这类问题。

**4. dracut 把网络带进了 initrd,约一半的开机 IPv6 链路本地地址 DAD 失败。** 26.04 用 dracut 生成 initramfs。
构建时 dracut 以 hostonly 模式在跑着 systemd-networkd 的构建 VM 上重生 initrd,`cloud-initramfs-dyn-netconf`
又依赖 `dracut-network`,结果 initrd 里有 `systemd-networkd`、`net-lib`、`dyn-netconf`,开机第 3 秒就把网卡
拉起来做了一轮 IPv6 DAD。与此同时 tap 上会出现一个带**本机 MAC**、目标是本机链路本地地址、但 **nonce 不同**
的 NS(在宿主 tap 上抓包实见,发送方尚未查明),撞上这轮 DAD 就被判为冲突:

```
IPv6: ens3: IPv6 duplicate address fe80::f816:3eff:fe75:23af used by fa:16:3e:75:23:af detected!
inet6 fe80::f816:3eff:fe75:23af/64 scope link dadfailed tentative
```

没有可用的链路本地地址,DHCPv6 就发不出 Solicit —— RaaS 管理网只有 IPv6、只靠 DHCPv6,机器因此永远连不上,
池子 boot_timeout 后清扫。当天池机器与探测机合计 26.04 约一半开机中招,24.04(initramfs-tools,initrd 不碰网卡)
一次没有;Ubuntu 官方 26.04 cloudimg 的 initrd 里也没有网络。**重启 networkd 修不了**,内核不会为已经
dadfailed 的地址重做 DAD;`ip link set down/up` 能。

修法:`configure-raas-initrd.sh` 写 `/etc/dracut.conf.d/90-raas-no-initrd-network.conf`
(`omit_dracutmodules+=" systemd-networkd net-lib dyn-netconf kernel-network-modules qemu-net "`),
`dracut --regenerate-all --force`,并在构建期检查每个 initrd 里都没有这些模块。一次性 VM 上验证过:重生后重启,
根盘照常挂载,initrd 阶段不再出现 `zzzz-dracut-default.network` 与网卡改名。RaaS 的 user-data 另有兜底
(发现 dadfailed 就弹链路,见 openstack-raas `doc/architecture.md` §4.6),修复前的镜像靠它开机。

## 收尾:镜像里不能留任何登录密钥(2026-09-08)

最后一个 provisioner 是我们自己的 `images/ubuntu/scripts/build/cleanup-openstack-image.sh`:清 cloud-init
状态、host key、machine-id、shell 历史,以及 **`/home/*/.ssh/authorized_keys` 与 root 的**。packer 是经
`ubuntu` 用户的 authorized_keys 登进构建 VM 的,那份文件否则会原样带进镜像 —— 2026-09-08 的 RaaS
Jenkins spike 就是靠它登进一台池镜像 VM 的。上游 Azure 线由 `waagent -deprovision+user` 兜住,
qemu/openstack 线得自己做。RaaS 的池 cloud-init 开机还会再删一次,作为第二道保险。
