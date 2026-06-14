#!/usr/bin/env bash
# define-vms.sh — run ON VANFRECKLESERV (Unraid), AFTER RAM install + host verification.
# Creates the NVMe-cache-pool vdisks and defines all four Talos VMs with the per-node
# disk topology of UPDATE 2026-06-13b. Idempotent-ish: skips disks/domains that exist.
# This DEFINES VMs in libvirt; it does NOT start them and does NOT touch any cluster.
#
# DRY_RUN=1 → validate-only: renders + xmllint-checks each VM XML, confirms the SATA
#   by-id guards, and defines NOTHING / creates no disk images / never calls virsh define.
#   Safe to run on any host (e.g. Nobara) where the SATA drives are NOT yet present — it
#   reports the by-id guard as "would pass on the target host" instead of hard-failing.
#   Usage:  DRY_RUN=1 ./vms/define-vms.sh
#
# Per-node hardware (templates in this dir):
#   cp1     → talos-cp1-lean      : system disk only (STORAGE-FREE)
#   cp2     → talos-cp2-nvme      : system + 50 GB NVMe-cache-pool Longhorn vdisk
#   cp3     → talos-cp3-sata      : system + passed-through SATA SSD (850 EVO) by-id
#   worker1 → talos-worker1-sata  : system + passed-through SATA SSD (MX500)  by-id
#
# PRE-FLIGHT (do not skip):
#   1. `free -h` shows 64 GiB after the 2×32 kit install
#   2. last night's R2 flash backup completed (rollback floor)
#   3. df -h on the cache pool — room for 4× system.img + cp2's longhorn.img
#   4. ISO at $VM_DISK_DIR/talos-metal-amd64.iso
#   5. The two SATA SSDs installed on INTERNAL ports; CP3_SATA_BYID + WORKER1_SATA_BYID
#      set in cluster.env to their real /dev/disk/by-id/ paths (NOT the USB-bridge id).
set -euo pipefail
cd "$(dirname "$0")/.."
source ./cluster.env
DRY_RUN="${DRY_RUN:-0}"
[[ "$DRY_RUN" == 1 ]] && echo "── DRY_RUN: validate only — no disks created, no VMs defined ──"

template_for() { case "$1" in
  cp1)     echo "vms/talos-cp1-lean.template.xml";;
  cp2)     echo "vms/talos-cp2-nvme.template.xml";;
  cp3)     echo "vms/talos-cp3-sata.template.xml";;
  worker1) echo "vms/talos-worker1-sata.template.xml";;
  *) echo "ERROR: no template for $1" >&2; return 1;;
esac }

make_vm() {  # $1=name $2=ram_mib
  local name="$1" ram="$2" vcpus="$3" dir="$VM_DISK_DIR/$1" tmpl byid="" out="/tmp/$1.xml"
  tmpl="$(template_for "$name")"

  # Disk images — skipped entirely in DRY_RUN (no writes anywhere).
  if [[ "$DRY_RUN" != 1 ]]; then
    mkdir -p "$dir"
    [[ -f "$dir/system.img" ]] || qemu-img create -f raw "$dir/system.img" "${SYSTEM_DISK_GB}G"
    if [[ "$name" == "cp2" ]]; then
      [[ -f "$dir/longhorn.img" ]] || qemu-img create -f raw "$dir/longhorn.img" "${CP2_LONGHORN_VDISK_GB}G"
    fi
  fi

  # cp3 / worker1: SATA passthrough guard.
  if [[ "$name" == "cp3" || "$name" == "worker1" ]]; then
    [[ "$name" == "cp3" ]] && byid="$CP3_SATA_BYID" || byid="$WORKER1_SATA_BYID"
    if [[ "$byid" == *TODO* ]]; then
      echo "SKIP $name: SATA by-id is still TODO in cluster.env."
      echo "     Install the drive internally, then: ls -l /dev/disk/by-id/ | grep -i ata-"
      echo "     and set the real path. (USB-bridge id is WRONG — do not use it.)"
      return 0
    fi
    if [[ -b "$byid" ]]; then
      echo "$name: SATA by-id guard PASS — $byid present as a block device."
    elif [[ "$DRY_RUN" == 1 ]]; then
      echo "$name: SATA by-id guard would PASS on target host (sentinel cleared: $byid)"
      echo "        — not a block device on THIS validation host (expected; the drive lives on VanFreckleServ)."
    else
      echo "ERROR $name: $byid is not a block device on this host"; return 1
    fi
  fi

  if [[ "$DRY_RUN" != 1 ]] && virsh dominfo "$name" &>/dev/null; then
    echo "exists: $name (already defined)"; return 0
  fi

  sed -e "s|__NAME__|$name|g" -e "s|__RAM_MIB__|$ram|g" \
      -e "s|__VCPUS__|$vcpus|g" -e "s|__DISK_DIR__|$VM_DISK_DIR|g" \
      -e "s|__BRIDGE__|$UNRAID_BRIDGE|g" -e "s|__SATA_BYID__|$byid|g" \
      "$tmpl" > "$out"

  if [[ "$DRY_RUN" == 1 ]]; then
    command -v xmllint >/dev/null && { xmllint --noout "$out" && echo "  XML well-formed: $out"; }
    if [[ -n "$byid" ]]; then
      grep -q -- "$byid" "$out" && echo "  by-id RESOLVED in XML: $byid" \
        || { echo "  ERROR: by-id NOT resolved in $out"; return 1; }
    fi
    echo "DRY-RUN rendered (NOT defined): $name (${ram}MiB, ${vcpus}vcpu) from $(basename "$tmpl")"
    return 0
  fi

  virsh define "$out"
  echo "defined: $name (${ram}MiB, ${vcpus}vcpu) from $(basename "$tmpl")"
}

make_vm "$NODE1_NAME" "$CP_RAM_MIB"     "$CP_VCPUS"      # cp1
make_vm "$NODE2_NAME" "$CP_RAM_MIB"     "$CP_VCPUS"      # cp2
make_vm "$NODE3_NAME" "$CP_RAM_MIB"     "$CP_VCPUS"      # cp3
make_vm "$NODE4_NAME" "$WORKER_RAM_MIB" "$WORKER_VCPUS"  # worker1

cat <<EOF

Start nodes ONE AT A TIME (cp1 first): virsh start ${NODE1_NAME}
Grab each node's DHCP IP from the console/VNC, then from Nobara:
  talosctl apply-config --insecure -n <dhcp-ip> -f talos/rendered/<node>.yaml
After install, eject the ISO before the next boot:
  virsh change-media <name> sda --eject --config
EOF
