#!/bin/bash

set -x

# generate Azure cloud provider config
if echo ${@} | grep -q "cloud-provider=azure"; then
  if [ "$1" = "kubelet" ] || [ "$1" = "kube-apiserver" ] || [ "$1" = "kube-controller-manager" ]; then
    source /opt/rke-tools/cloud-provider.sh
    set_azure_config
    # If set_azure_config is called debug needs to be turned back on
    set -x
  fi
fi

DOCKER_ROOT=$(DOCKER_API_VERSION=1.24 /opt/rke-tools/bin/docker info 2>&1  | grep -i 'docker root dir' | cut -f2 -d:)
DOCKER_DIRS=$(find -O1 $DOCKER_ROOT -maxdepth 1) # used to exclude mounts that are subdirectories of $DOCKER_ROOT to ensure we don't unmount mounted filesystems on sub directories
for i in $DOCKER_ROOT /var/lib/docker /run /var/run; do
    for m in $(tac /proc/mounts | awk '{print $2}' | grep ^${i}/); do
        if [ "$m" != "/var/run/nscd" ] && [ "$m" != "/run/nscd" ] && ! echo $DOCKER_DIRS | grep -qF "$m"; then
            umount $m || true
        fi
    done
done

if [ "$1" = "kubelet" ]; then
    mount --rbind /host/dev /dev
    mount -o rw,remount /sys/fs/cgroup 2>/dev/null || true
    for i in /sys/fs/cgroup/*; do
        if [ -d $i ]; then
             mkdir -p $i/kubepods
        fi
    done

    mkdir -p /sys/fs/cgroup/cpuacct,cpu/
    mount --bind /sys/fs/cgroup/cpu,cpuacct/ /sys/fs/cgroup/cpuacct,cpu/
    mkdir -p /sys/fs/cgroup/net_prio,net_cls/
    mount --bind /sys/fs/cgroup/net_cls,net_prio/ /sys/fs/cgroup/net_prio,net_cls/

    # If we are running on SElinux host, need to:
    mkdir -p /opt/cni /etc/cni
    chcon -Rt svirt_sandbox_file_t /etc/cni 2>/dev/null || true
    chcon -Rt svirt_sandbox_file_t /opt/cni 2>/dev/null || true

    # Set this to 1 as required by network plugins
    # https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/#network-plugin-requirements
    sysctl -w net.bridge.bridge-nf-call-iptables=1 || true

    if [ -f /host/usr/lib/os-release ]; then
        ln -sf /host/usr/lib/os-release /usr/lib/os-release
    elif [ -f /host/etc/os-release ]; then
        ln -sf /host/etc/os-release /usr/lib/os-release
    elif [ -f /host/usr/share/ros/os-release ]; then
        ln -sf /host/usr/share/ros/os-release /usr/lib/os-release
    fi

    # Check if no other or additional resolv-conf is passed (default is configured as /etc/resolv.conf)
    if echo "$@" | grep -q -- --resolv-conf=/etc/resolv.conf; then
        # Check if host is running `system-resolved`
        if pgrep -f systemd-resolved > /dev/null; then
            # Check if the resolv.conf with the actual nameservers is present
            if [ -f /run/systemd/resolve/resolv.conf ]; then
                RESOLVCONF="--resolv-conf=/run/systemd/resolve/resolv.conf"
            fi
        fi
    fi

    if [ ! -z "${RKE_KUBELET_DOCKER_CONFIG}" ]
    then
      echo ${RKE_KUBELET_DOCKER_CONFIG} | base64 -d | tee ${RKE_KUBELET_DOCKER_FILE}
    fi

    CGROUPDRIVER=$(/opt/rke-tools/bin/docker info | grep -i 'cgroup driver' | awk '{print $3}')

    # final step for kubelet
    exec "$@" --cgroup-driver=$CGROUPDRIVER $RESOLVCONF
fi

exec "$@"
