#!/usr/bin/env bash
# gen-configs.sh — render all Talos machine configs from cluster.env.
# Run on Nobara. Requires: talosctl, yq.  OFFLINE except the version checks talosctl
# itself does. This script RENDERS and VALIDATES configs; it does NOT apply anything.
#
# Output → talos/rendered/ (GIT-IGNORED — embeds cluster secrets). The committed
# source of truth is: cluster.env + talos/patches/* + this script.
#
# Per-node patch stacks (storage topology = UPDATE 2026-06-13b, replica-3):
#   cp1     (lean)   : common + cp-schedule + vip(cp1)                          [NO Longhorn]
#   cp2     (storage): common + cp-schedule + vip(cp2) + longhorn-volume + longhorn-kubelet
#   cp3     (storage): common + cp-schedule + vip(cp3) + longhorn-volume + longhorn-kubelet
#   worker1 (storage): common + vip(worker1, no VIP) + longhorn-volume + longhorn-kubelet  [NO cp-schedule]
# common is applied at `gen config` time; the rest are layered per node below.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./cluster.env

# ── Guard rails ──────────────────────────────────────────────────────────────
[[ "$SCHEMATIC_ID" == *CHANGE_ME* ]] && { echo "ERROR: SCHEMATIC_ID not set in cluster.env"; exit 1; }
[[ "$VIP" == *CHANGE_ME* || "$GATEWAY" == *CHANGE_ME* ]] && { echo "ERROR: fill network values in cluster.env"; exit 1; }
command -v yq >/dev/null || { echo "ERROR: yq required"; exit 1; }

P="talos/patches"
OUT="talos/rendered"
mkdir -p "$OUT"

# Storage nodes get the Longhorn patches; everything else is keyed off role.
is_storage() { case "$1" in cp2|cp3|worker1) return 0;; *) return 1;; esac; }

# 1. Cluster secrets — generated ONCE, stored OUTSIDE git (Vaultwarden secure note).
#    Re-running with the same secrets.yaml keeps configs reproducible.
if [[ ! -f "$OUT/secrets.yaml" ]]; then
  talosctl gen secrets -o "$OUT/secrets.yaml"
  echo ">> NEW $OUT/secrets.yaml generated — BACK IT UP TO VAULTWARDEN NOW (irreplaceable)."
fi

# 2. Base configs against the VIP endpoint.
#    🛑 --kubernetes-version PINS k8s 1.35.4 — without it we inherit Talos 1.13.3's
#       bundled k8s 1.36, ABOVE Longhorn 1.11.2's tested ceiling. Single most important flag.
talosctl gen config "$CLUSTER_NAME" "$K8S_ENDPOINT" \
  --with-secrets "$OUT/secrets.yaml" \
  --install-image "$INSTALL_IMAGE" \
  --kubernetes-version "$KUBERNETES_VERSION" \
  --config-patch @"$P/common.yaml" \
  --output-dir "$OUT" --force

# 2b. Talos v1.13 emits a separate `HostnameConfig` document (auto: stable) which
#     CONFLICTS with the explicit machine.network.hostname each vip patch sets
#     ("'auto' and 'hostname' cannot be set at the same time"). We set hostnames
#     explicitly (cp1/cp2/cp3/worker1), so drop the auto document from the base.
for b in controlplane worker; do
  yq -i 'select(.kind != "HostnameConfig")' "$OUT/$b.yaml"
done

# 3. Render one VIP patch per node (strip the VIP block on the worker via yq).
render_vip() {  # $1=name $2=ip $3=role
  local f="$OUT/vip-$1.yaml"
  sed -e "s|__HOSTNAME__|$1|g" -e "s|__NODE_IP__|$2|g" \
      -e "s|__CIDR__|$NETMASK_CIDR|g" -e "s|__GATEWAY__|$GATEWAY|g" \
      -e "s|__VIP__|$VIP|g" -e "s|__NAMESERVER__|$NAMESERVER|g" \
      "$P/vip-patch.template.yaml" > "$f"
  if [[ "$3" == "worker" ]]; then
    yq -i 'del(.machine.network.interfaces[0].vip)' "$f"   # worker carries NO VIP
  fi
}

# 4. Assemble each node's final config = role base + its patch stack.
assemble() {  # $1=name $2=ip $3=role
  local name="$1" ip="$2" role="$3"
  local base="controlplane.yaml"; [[ "$role" == "worker" ]] && base="worker.yaml"
  render_vip "$name" "$ip" "$role"

  local patches=()
  [[ "$role" == "controlplane" ]] && patches+=( "$P/cp-schedule.yaml" )
  patches+=( "$OUT/vip-$name.yaml" )
  if is_storage "$name"; then
    # SATA-passthrough nodes (worker1/cp3) get the transport+size selector;
    # cp2's NVMe vdisk uses the !system_disk variant.
    case "$name" in
      cp2) patches+=( "$P/longhorn-volume-nvme.yaml" );;
      *)   patches+=( "$P/longhorn-volume-sata.yaml" );;
    esac
    patches+=( "$P/longhorn-kubelet.yaml" )
  fi

  local args=(); for p in "${patches[@]}"; do args+=( --patch "@$p" ); done
  talosctl machineconfig patch "$OUT/$base" "${args[@]}" --output "$OUT/$name.yaml"

  # 5. Validate OFFLINE (schema + metal-mode rules). NEVER touches a cluster.
  talosctl validate --config "$OUT/$name.yaml" --mode metal
  echo "rendered + validated: $OUT/$name.yaml  [${role}$(is_storage "$name" && echo ', storage')]"
}

for n in 1 2 3 4; do
  nm="NODE${n}_NAME"; ip="NODE${n}_IP"; rl="NODE${n}_ROLE"
  assemble "${!nm}" "${!ip}" "${!rl}"
done

cat <<EOF

DONE. Rendered configs in $OUT/ (git-ignored). Saturday apply order (one node at a time):
  talosctl apply-config --insecure -n <node-dhcp-ip> -f $OUT/cp1.yaml      # then cp2, cp3, worker1
  talosctl bootstrap -n $NODE1_IP -e $NODE1_IP                             # 🛑 ONCE, cp1 only
  talosctl kubeconfig -n $VIP -e $VIP ./kubeconfig-cartarch-prod
Back up $OUT/secrets.yaml + talosconfig to Vaultwarden before doing ANY of the above.
EOF
