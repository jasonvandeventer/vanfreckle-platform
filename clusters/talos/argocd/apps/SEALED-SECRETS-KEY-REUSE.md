# Sealed Secrets — master key reuse

The new cluster REUSES the old cluster's sealing key so every committed SealedSecret
decrypts unchanged. Do NOT generate a new key (every existing SealedSecret would fail).

## ⚠️ Correction vs. the old prestage note
The controller runs in the **`sealed-secrets`** namespace with
`fullnameOverride: sealed-secrets-controller` (mirrored from the old cluster's
`k8s/argocd/apps/sealed-secrets.yaml`). The signing key therefore lives in the
**`sealed-secrets`** namespace — NOT `kube-system`. Export and restore it there.

## Sequence
1. **Export from the OLD cluster** (pre-staging week; store in Vaultwarden, NEVER git):
   ```bash
   kubectl -n sealed-secrets get secret \
     -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
     -o yaml > sealed-secrets-key-backup.yaml
   ```
   (If the label selector returns nothing, list with
   `kubectl -n sealed-secrets get secret` and grab the `*-key*` TLS secret.)

2. **On the NEW cluster, BEFORE the sealed-secrets app syncs:**
   ```bash
   kubectl create ns sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
   kubectl apply -f sealed-secrets-key-backup.yaml
   ```

3. **Then sync the `sealed-secrets` Application** (same chart 2.18.6). The controller
   picks up the restored key on startup. Verify a known SealedSecret decrypts.

`sealed-secrets-key-backup.yaml` is git-ignored (see repo `.gitignore`).
