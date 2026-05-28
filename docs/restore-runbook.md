# Restore Runbook — Longhorn Volume Recovery

**Last Updated:** 2026-05-28
**First captured after:** 2026-05-28 cartarch volume ext4 metadata corruption incident
**Longhorn version this applies to:** v1.11.x

## Purpose

Procedure for recovering a Longhorn volume from the failure modes that have actually happened on this platform. Updated as new failure modes are encountered.

## Failure Modes Covered

### Mode 1: ext4 metadata corruption blocking pod mount

**Symptoms:**
- Pod stuck in `Init:0/1` or `ContainerCreating`
- `kubectl describe pod` shows `FailedMount` events
- Error contains `'fsck' found errors on device /dev/longhorn/pvc-... but could not correct them`
- Specific message often `Resize inode not valid` or other ext4 metadata error
- The kubelet runs `fsck -a` before mount; `-a` mode only fixes uncontroversial errors

**This is almost always recoverable with `e2fsck -fy`.** The kubelet refuses to repair errors that flag for human review; manual `e2fsck` is willing to make the repair.

**Do NOT first try:** snapshot revert. If the metadata corruption has been latent in the filesystem for some time, every snapshot in the chain carries the same flaw forward. Reverting wastes time and discards recent data unnecessarily.

**Procedure:**

1. **Disable selfHeal on the Application AND any app-of-apps parent.**

   A patch on just `mana-archive` is reverted by `platform-root` within seconds. Both must be patched.

   ```bash
   kubectl patch application mana-archive -n argocd --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":true}}}}'
   kubectl patch application platform-root -n argocd --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":true}}}}'
   ```

   Verify:

   ```bash
   kubectl get application platform-root mana-archive -n argocd \
     -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.syncPolicy.automated}{"\n"}{end}'
   # Expect both: {"prune":true,"selfHeal":false}
   ```

2. **Scale the deployment to 0.**

   ```bash
   kubectl scale deployment mana-archive -n mana-archive --replicas=0
   ```

   Wait for the pod to terminate. The FailedMount loop stops once no pod is requesting the volume.

3. **Take a current-state snapshot before any modifications.**

   Forensic safety net. If anything in the recovery makes things worse, you can restore to "the corrupted state we started from."

   ```bash
   kubectl annotate volume.longhorn.io pvc-<UUID> -n longhorn-system \
     longhorn.io/snapshot-now=pre-recovery-$(date -u +%Y-%m-%d) --overwrite
   ```

4. **Attach the volume in maintenance mode (frontend ENABLED) to a worker node.**

   "Frontend enabled" sounds counterintuitive, but it's required: with `disableFrontend: true` the engine runs but no `/dev/longhorn/*` block device is exposed, which means fsck has nothing to operate on. With frontend enabled, the device exists; with the deployment scaled to 0 and selfHeal off, nothing else in the cluster will try to mount it via CSI.

   In Longhorn v1.11.x, attaching requires patching the `VolumeAttachment` CR (not the `Volume` CR directly — `Volume.spec.nodeID` patches are reverted by the VolumeAttachmentController).

   ```bash
   kubectl patch volumeattachment.longhorn.io pvc-<UUID> -n longhorn-system \
     --type=merge -p '{"spec":{"attachmentTickets":{"operator-fsck":{
       "id":"operator-fsck","nodeID":"node4","type":"longhorn-api",
       "parameters":{"disableFrontend":"false"}}}}}'
   ```

   Wait for `state: attached`, `robustness: healthy`:

   ```bash
   kubectl get volume.longhorn.io pvc-<UUID> -n longhorn-system \
     -o jsonpath='{"state: "}{.status.state}{" robustness: "}{.status.robustness}{" node: "}{.status.currentNodeID}{" frontend: "}{.status.frontendDisabled}{"\n"}'
   # Expect: state: attached  robustness: healthy  node: node4  frontend: false
   ```

5. **Identify the instance-manager pod on the attached node.**

   ```bash
   IM_POD=$(kubectl get pods -n longhorn-system \
     -l longhorn.io/component=instance-manager \
     --field-selector spec.nodeName=node4 \
     -o jsonpath='{.items[0].metadata.name}')
   echo "Instance manager: $IM_POD"

   # Confirm our volume's block device is present:
   kubectl exec -n longhorn-system "$IM_POD" -- ls /dev/longhorn/
   # Expect pvc-<UUID> in the listing
   ```

6. **Run manual fsck.**

   `-f` forces a check even on a "clean" filesystem; `-y` answers yes to all repair prompts. For metadata corruption like "Resize inode not valid," the repairs are typically bookkeeping (resize inode recreation, bitmap counter fixes) and do not touch user data.

   ```bash
   kubectl exec -n longhorn-system "$IM_POD" -- \
     e2fsck -fy /dev/longhorn/pvc-<UUID>
   ```

   **Read the entire output.** Look for:

   - `Pass 1` through `Pass 5` running cleanly
   - The specific repair messages (e.g. `Resize inode not valid.  Recreate? yes`, `Block bitmap differences ... Fix? yes`)
   - Final summary: `FILE SYSTEM WAS MODIFIED` followed by file/block usage statistics
   - Exit code `1` from `kubectl exec` (success-with-repairs; not actually an error in this context)

   **Stop if you see:** any prompt to clear specific inodes by number, move files to `lost+found`, or "Add to badblocks." Those are data-touching repairs that warrant a pause and review.

7. **Detach the volume by removing the maintenance ticket.**

   ```bash
   kubectl patch volumeattachment.longhorn.io pvc-<UUID> -n longhorn-system \
     --type=json -p='[{"op": "remove", "path": "/spec/attachmentTickets/operator-fsck"}]'

   # Wait for detach
   kubectl get volume.longhorn.io pvc-<UUID> -n longhorn-system \
     -o jsonpath='{"state: "}{.status.state}{"\n"}'
   # Re-run until: state: detached
   ```

8. **Scale the deployment back up and watch the pod come up.**

   ```bash
   kubectl scale deployment mana-archive -n mana-archive --replicas=1
   kubectl get pods -n mana-archive -w
   ```

   Expected lifecycle:
   - `Pending` → `ContainerCreating` → `Init:0/1` → `PodInitializing` → `Running`
   - Typical total time: 30-60 seconds

   If `FailedMount` returns: the fsck didn't address all corruption. Re-run with verbose logging (`e2fsck -fvy`) and read output carefully.

9. **Verify the app actually works.**

   Pod running ≠ app working. Test:
   - Tail logs for normal startup
   - `curl https://cartarch.com/ -o /dev/null -w '%{http_code}\n'` (HEAD won't work; GET will)
   - Browser: load app, log in, exercise read AND write paths

10. **Re-enable selfHeal.**

    Order: app first, then app-of-apps. Verify both flipped before walking away.

    ```bash
    kubectl patch application mana-archive -n argocd --type merge \
      -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}'
    kubectl patch application platform-root -n argocd --type merge \
      -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}'

    kubectl get application platform-root mana-archive -n argocd \
      -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.syncPolicy.automated}{"\n"}{end}'
    # Expect both: {"prune":true,"selfHeal":true}
    ```

    **Before re-enabling, verify Git matches the running state.** During incidents, the deployment image may differ from what Git says. If Git holds an older image than what's running, selfHeal will roll the deployment backwards. Check:

    ```bash
    # Current running image
    kubectl get deployment mana-archive -n mana-archive \
      -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'

    # What Git's kustomization says
    grep -A1 'mana-archive$' k8s/apps/mana-archive/base/kustomization.yaml
    ```

    If they differ, update the kustomization first (bump `newTag`), commit, push, wait for ArgoCD to register the new HEAD as synced, *then* re-enable selfHeal.

---

### Mode 2: Snapshot revert (not for ext4 corruption — see above)

**When to use:**
- A logical-level problem (bad migration, accidental data deletion, application-level corruption)
- The data on the volume is wrong but the *filesystem itself* is consistent

**When NOT to use:**
- ext4 metadata corruption: see Mode 1. Reverting won't fix structural metadata issues.

**Procedure outline (Longhorn v1.11.x):**

1. Disable selfHeal on app and app-of-apps (same as Mode 1 step 1)
2. Scale deployment to 0
3. Take a current-state snapshot for forensic safety
4. Attach in maintenance mode with `disableFrontend: true` (block device NOT needed; only the engine matters for snapshot ops)
5. Identify the target snapshot from the engine's snapshot list (`?action=snapshotList`)
6. Issue revert via Longhorn manager API (port 9500). Note: `kubectl port-forward` fails because the manager binds to its pod IP, not localhost. Use `kubectl exec` into a manager pod and `curl` against `$(kubectl get pod ... -o jsonpath='{.status.podIP}')`:

   ```bash
   LH_MGR=$(kubectl get pods -n longhorn-system -l app=longhorn-manager \
     -o jsonpath='{.items[0].metadata.name}')
   POD_IP=$(kubectl get pod "$LH_MGR" -n longhorn-system \
     -o jsonpath='{.status.podIP}')

   kubectl exec -n longhorn-system "$LH_MGR" -c longhorn-manager -- \
     curl -s -X POST -H "Content-Type: application/json" \
     -d '{"name":"snapshot-<TARGET-UUID>"}' \
     "http://${POD_IP}:9500/v1/volumes/pvc-<UUID>?action=snapshotRevert"
   ```

   Expected response: `HTTP/1.1 200 OK` with empty body. Python parse errors on empty body are NOT API failures — verify with `-i` for the HTTP status code.

7. Verify the revert took:

   ```bash
   kubectl exec -n longhorn-system "$LH_MGR" -c longhorn-manager -- \
     curl -s -X POST \
     "http://${POD_IP}:9500/v1/volumes/pvc-<UUID>?action=snapshotList" \
     | python3 -c "
   import json, sys
   data = json.load(sys.stdin)
   for s in data.get('data', []):
       if s.get('name') == 'volume-head':
           print('volume-head parent:', s.get('parent'))
           break"
   # Expect: volume-head parent: snapshot-<TARGET-UUID>
   ```

8. Detach by removing the maintenance ticket (same as Mode 1 step 7)
9. Scale back up, verify, re-enable selfHeal (Mode 1 steps 8-10)

---

## Known Quirks Learned the Hard Way

### Longhorn UI snapshot tree view sometimes renders empty

On `revisionCounterDisabled: true` volumes (or possibly in other situations), the UI's snapshot tree visualization may render as empty even when snapshots exist. The CLI/API view will show them. Don't trust the UI as the source of truth for "do snapshots exist."

### `kubectl port-forward` against Longhorn manager will fail

The manager process binds to the pod IP, not `0.0.0.0`. `port-forward` (against either the pod or the `longhorn-backend` Service) returns connection refused. Use `kubectl exec` and curl from inside a manager pod against its own pod IP.

### `volume.spec.nodeID` patches are reverted by VolumeAttachmentController

In v1.11.x, attaches must go through a `VolumeAttachment` CR with an `attachmentTicket`. Direct patches to `volume.spec.nodeID` are reconciled away within seconds.

### `selfHeal:false` patch on a child Application is reverted by its app-of-apps parent

`platform-root` will revert `mana-archive`'s `syncPolicy` if it differs from Git. Disable selfHeal on *both* the child Application and its app-of-apps parent before any cluster-state recovery work.

### Empty HTTP body is success, not failure

Longhorn manager API actions (e.g. `snapshotRevert`) return `HTTP/1.1 200 OK` with `Content-Length: 0`. Python parsing the body as JSON will raise `Expecting value: line 1 column 1 (char 0)` — that's not an API failure. Always send action POSTs with `curl -i` to see the actual HTTP status.

### Frontend disabled = no block device, frontend enabled = block device exposed

For snapshot ops: `disableFrontend: true` is correct (no /dev/longhorn/* needed, just the engine).
For fsck: `disableFrontend: false` is required (need /dev/longhorn/* to exist).
This is not always intuitive from the parameter name.

---

## Cross-References

- `backup-strategy.md` — current backup posture and gaps
- `roadmap.md` → *Resilience & Production-Readiness* — broader operational maturity
- `docs/decisions/local-path-default-class-fix.md` — for the StorageClass drift pattern
- `docs/decisions/argocd-repo-hygiene.md` — for app-of-apps and finalizer issues
