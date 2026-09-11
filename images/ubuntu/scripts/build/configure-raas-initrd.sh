#!/usr/bin/env bash
# Keep networking out of the initrd (docs/openstack.md, "Ubuntu 26.04" pitfall 4).
#
# 26.04 builds its initramfs with dracut. When the image is built, dracut runs in hostonly
# mode on a build VM that has systemd-networkd up, and cloud-initramfs-dyn-netconf pulls in
# dracut-network - so the initrd ends up with systemd-networkd, net-lib and dyn-netconf and
# brings the NIC up about 3 seconds into boot. That early bring-up runs IPv6 DAD on the
# link-local address while a stray NS carrying the NIC's own MAC and link-local target (with
# a different nonce) shows up on the tap; the kernel reports
# "IPv6 duplicate address fe80::... used by <own MAC> detected!", leaves the link-local
# dadfailed, and DHCPv6 on the RaaS management network never starts. On 2026-09-11 that hit
# about half of the boots of raas-runner-ubuntu-26.04-20260911.1; restarting networkd does not
# help because the kernel never re-runs DAD for an address that already failed.
#
# Nothing we boot needs a network in the initrd: the root disk is local. 24.04 uses
# initramfs-tools, whose initrd never touches the NIC, and has never shown the failure.
set -euo pipefail

if ! command -v dracut >/dev/null 2>&1; then
    echo "dracut is not installed (initramfs-tools image); nothing to do"
    exit 0
fi

NET_MODULES="systemd-networkd net-lib dyn-netconf kernel-network-modules qemu-net"

install -d -m 0755 /etc/dracut.conf.d
cat > /etc/dracut.conf.d/90-raas-no-initrd-network.conf <<EOF
# Written by configure-raas-initrd.sh: no networking in the initrd (see that script).
omit_dracutmodules+=" ${NET_MODULES} "
EOF

dracut --regenerate-all --force

# Self-check at build time: a regression here only shows up as machines that
# intermittently never get a management address.
status=0
for initrd in /boot/initrd.img-*; do
    present=$(lsinitrd "$initrd" | sed -n '/^dracut modules:/,/^=/p' | grep -xE "$(echo "$NET_MODULES" | tr ' ' '|')" || true)
    if [ -n "$present" ]; then
        echo "initrd $initrd still contains network modules: $(echo "$present" | tr '\n' ' ')"
        status=1
    else
        echo "initrd $initrd: no network modules"
    fi
done
exit $status
