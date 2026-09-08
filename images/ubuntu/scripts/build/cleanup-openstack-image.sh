#!/bin/bash -e
################################################################################
##  File:  cleanup-openstack-image.sh
##  Desc:  Last provisioner for the OpenStack / QEMU images. Strips everything
##         that must not survive into a booted machine: cloud-init state, host
##         keys, machine-id, shell history — and every SSH authorized key.
##
##         The authorized keys are the important line. Packer logs into the
##         build VM through the `ubuntu` user's authorized_keys; that file is
##         otherwise carried verbatim into the image, so every machine booted
##         from it accepted the build host's key (found 2026-09-08 by the RaaS
##         Jenkins spike: it was how we got in). Azure images avoid this via
##         `waagent -deprovision+user`; we have to do it ourselves.
################################################################################

# Let cloud-init and the package manager settle before we pull the rug.
sleep 30

# No login material may survive: build-time keys are not production keys.
rm -f /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys

# First boot must look like a first boot.
cloud-init clean --logs --seed
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

export HISTSIZE=0
sync
