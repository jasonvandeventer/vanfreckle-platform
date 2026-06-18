# Phase-4 Patch D — disk-cache  (NOT a Talos config patch — a VM-template setting)

**This is deliberately a `.README.md`, not a `disk-cache.yaml`.** The build guide
(Phase 4, Patch D) is explicit: the etcd-fsync disk-cache control is a **qemu/libvirt
VM-template setting**, NOT something expressible in a Talos machine config. Authoring
it as a Talos patch would either fail `talosctl validate` or silently do nothing, so
it lives where it actually takes effect: the VM XML.

## What it controls
etcd is fsync-sensitive, and every node's **system disk is a file on the one shared
ZFS NVMe cache pool**. If the qemu disk uses `cache='writeback'`, fsyncs are buffered
in host RAM and **lie** — etcd believes its WAL is durable when it is not. Under load
this surfaces as leader-election flapping and "the cluster got flaky." The fix is to
set the **control-plane system vdisk bus cache to `none` (or `directsync`)** so fsync
means fsync.

## Where it is implemented
`vms/*.template.xml` — every control-plane VM (cp1, cp2, cp3) sets:

```xml
<driver name='qemu' type='raw' cache='none' discard='unmap'/>
```

on its **system** disk (and on cp2's NVMe Longhorn vdisk). The worker keeps the
default. This replaces the `cache='writeback'` the original template used on every
disk.

## Verify after cutover (Phase 8)
Watch the etcd WAL fsync p99 in Grafana — sustained spikes here are the NVMe
contention loop, and the first thing to check is that the CP system disks did NOT
get reset to `writeback` by an Unraid VM-template edit:

```promql
histogram_quantile(0.99, sum(rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) by (le))
```

Healthy = low-single-digit ms. (Longhorn replica IO now lives mostly on the SATA SSDs
per the 2026-06-13 addendum, so the contention cascade is largely defused — but cp2's
NVMe vdisk replica re-introduces *partial* contention on cp2's etcd, so cp2 is the
node to watch.)
