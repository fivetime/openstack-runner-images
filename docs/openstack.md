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

## 收尾:镜像里不能留任何登录密钥(2026-09-08)

最后一个 provisioner 是我们自己的 `images/ubuntu/scripts/build/cleanup-openstack-image.sh`:清 cloud-init
状态、host key、machine-id、shell 历史,以及 **`/home/*/.ssh/authorized_keys` 与 root 的**。packer 是经
`ubuntu` 用户的 authorized_keys 登进构建 VM 的,那份文件否则会原样带进镜像 —— 2026-09-08 的 RaaS
Jenkins spike 就是靠它登进一台池镜像 VM 的。上游 Azure 线由 `waagent -deprovision+user` 兜住,
qemu/openstack 线得自己做。RaaS 的池 cloud-init 开机还会再删一次,作为第二道保险。
