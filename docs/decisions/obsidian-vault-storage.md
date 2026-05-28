# Decision: Obsidian Vault Storage (hostPath PV, not Longhorn)

**Date:** 2026-05-27
**Status:** Decided; implementation tracked as part of `roadmap.md` Near-Term item 5

## Context

`roadmap.md` Near-Term item 5 ships `obsidian-mcp`, which exposes the operator's Obsidian documentation vault for read/write/edit/auto-link access by Claude.ai and Claude Code. The vault holds the design documentation for cartarch and is the source of design intent for the app.

The vault lives on the operator's workstation. The MCP pod runs in k3s. The MCP must have file-level read/write access to the vault from inside the cluster.

The platform's `CLAUDE.md` rules include "Longhorn is the default StorageClass." Default storage for new workloads is Longhorn. The Obsidian vault PVC is the first deliberate exception this platform has needed; an ADR exists so the exception stays *visible* and not a silent escape hatch — analogous in shape to `docs/decisions/local-path-default-class-fix.md`.

## Decision

**The Obsidian vault is mounted into `obsidian-mcp` via a `hostPath` PersistentVolume pointing at a Syncthing-replicated directory on the Unraid host.** Not via Longhorn.

Syncthing keeps the vault in sync between the operator's workstation and an Unraid share (e.g. `/mnt/user/syncthing/obsidian-vault`). A `hostPath` PV with `storageClassName: manual` exposes that directory to the cluster. The `obsidian-mcp` Deployment binds a PVC to that PV and mounts it at `/vault` inside the container.

## Rationale

Longhorn is the wrong substrate for this data for three reasons:

1. **Source of truth lives outside the cluster.** The canonical vault is on the operator's workstation, accessed by Obsidian directly. Syncthing replicates it to Unraid. Putting Longhorn in the chain would be a second replication layer on top of Syncthing — added complexity, no benefit, and the kind of "clever" architecture the guiding principles explicitly warn against.
2. **Longhorn capacity is currently the binding constraint.** Per `roadmap.md` Resilience tier, the cluster VMs each run on ~34Gi root filesystems with no headroom; Longhorn can place only ~7–9Gi per node. The Unraid array has 12TB the VMs cannot see. The vault's home on the Unraid array is the right place for it; routing it through Longhorn would consume scarce capacity for no benefit.
3. **The replication semantics are different.** Longhorn replicates blocks across cluster nodes. Syncthing replicates files across devices — including the operator's phone and laptop, neither of which is a cluster node. The "replication" the vault needs is Syncthing's, not Longhorn's.

The `hostPath` PV is honest about all of this: it says "this data lives on the Unraid host, the cluster reaches it directly, that is the actual architecture."

## Consequences

**Positive:**

- Vault remains accessible to Obsidian, the operator's phone/laptop, and the MCP pod via the same Syncthing-replicated directory
- No Longhorn capacity consumed
- Recovery is via Syncthing, not Longhorn snapshots — appropriate for this data class

**Tradeoffs accepted:**

- **Node affinity.** A `hostPath` PV ties the pod to whichever node can see that path. With Unraid as the host and four VMs as the nodes, the `hostPath` works on any node only if the path is consistently mounted across all four VMs. This is achievable (mount the Unraid share into each VM at the same path) and is part of the implementation work. Documented here so the constraint is visible. If consistency proves operationally annoying, the fallback is to `nodeAffinity` the `obsidian-mcp` pod to a single node where the mount exists.
- **No Longhorn snapshots.** Volume restore happens via Syncthing's own file-versioning, not Longhorn snapshots. Acceptable for documentation data where per-file history is more useful than block-level snapshots anyway.
- **Concurrent writes.** Both Obsidian (operator) and `obsidian-mcp` (Claude) can write to the same files. Syncthing handles this with `.sync-conflict-*` files on collision. In practice the operator and Claude rarely edit the same note simultaneously; when they do, the conflict file is a recoverable artefact, not data loss.

**Precedent set:**
This is the first deliberate exception to the "Longhorn is default" rule. The pattern — `hostPath` PV against a host-managed directory, justified by an ADR — is now available for future cases where data legitimately lives outside the cluster's storage system. The ADR exists explicitly so this stays a *deliberate exception* and not a *silent escape hatch*.

## Alternatives considered

- **Longhorn volume + Syncthing client running in-cluster.** A Syncthing pod inside the cluster, pointed at the operator's workstation over the network, writing into a Longhorn PVC. Rejected: doubles the replication chain, consumes Longhorn capacity, and adds a stateful Syncthing pod to operate. The simpler architecture (Syncthing on Unraid + `hostPath` PV) achieves the same goal with less surface area.
- **NFS PV pointing at an Unraid NFS export of the same directory.** Functionally equivalent to `hostPath` for this case, but adds a network protocol where a filesystem mount is sufficient. `hostPath` is the lighter pattern when the cluster nodes can reach the directory directly. If a future need arises to access this from outside the host's filesystem (e.g. external nodes after a hosting decision), NFS becomes the right pattern.
- **Obsidian Sync or Obsidian LiveSync (self-hosted CouchDB).** Considered as the replication mechanism. Rejected in favor of Syncthing for its simplicity and zero per-user cost; the platform already has Syncthing as a candidate for other replication needs.

## References

- `roadmap.md` Near-Term item 5 (MCP deployment — this work's tracking entry)
- `roadmap.md` Resilience & Production-Readiness → Longhorn capacity (the binding capacity constraint)
- `CLAUDE.md` Rules ("Longhorn is the default StorageClass" — the rule this exception is against)
- `docs/decisions/local-path-default-class-fix.md` (the analogous pattern: a non-default StorageClass kept under GitOps so the exception is visible)
- `cluster-layout.md` StorageClasses table (`manual` row)
