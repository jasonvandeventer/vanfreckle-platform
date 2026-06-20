#!/usr/bin/env bash
# =============================================================================
# green-health-check.sh  —  READ-ONLY diagnostic for the Talos "green" cluster
#                           (kube context: admin@cartarch-prod)
# =============================================================================
# Diagnoses post-crash recovery state. It DIAGNOSES, it does NOT FIX.
#
#   * Default mode: every command is read-only (get / describe / logs / config).
#     NOTHING is created, deleted, applied, restarted, or scaled.
#   * Optional `--conn-test`: the ONLY mutating section. It creates two tiny
#     ephemeral busybox pods (pinned to worker1 + cp1), runs cross-node
#     connectivity probes between them, then DELETES them (trap-guaranteed
#     cleanup, even on Ctrl-C). It creates nothing else. Off by default.
#
# Idempotent & re-runnable — safe to run repeatedly to watch recovery progress.
# Writes a timestamped report to scripts/green-health-reports/ AND stdout.
#
# Usage:
#   ./green-health-check.sh                 # pure read-only sweep (default)
#   ./green-health-check.sh --conn-test     # ALSO do the cross-node pod test
#   GREEN_KUBECONFIG=/path ./green-health-check.sh   # override green kubeconfig
#
# Context: green hard-crashed (host OOM -> power-cut) 2026-06-19 evening. Post-
# crash symptom: cross-node pod-to-pod networking failing (argocd application-
# controller on worker1 could not reach the argocd-repo-server Service on cp1).
# Full context: ai-context/cartarch/incident-host-oom-cluster-bringup-2026-06-19.md
# =============================================================================

set -uo pipefail   # NOT -e: a failing diagnostic must be REPORTED, never abort the sweep.

# ------------------------------------------------------------------ paths/config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Default to the repo's green kubeconfig. Do NOT inherit an ambient KUBECONFIG
# (which might point at blue/k3s) — this script is green-only, and the context
# assertion below is a hard guard against ever pointing it elsewhere.
export KUBECONFIG="${GREEN_KUBECONFIG:-$REPO_ROOT/kubeconfig-cartarch-prod}"

EXPECT_CONTEXT="admin@cartarch-prod"
ARGO_APP="cnpg-cartarch-prod"        # the app whose ComparisonError is the symptom
TEST_NODE_A="worker1"                # cross-node test endpoints (the failing path)
TEST_NODE_B="cp1"
TEST_NS="default"
RUN_CONN_TEST=0
for arg in "$@"; do
  case "$arg" in
    --conn-test) RUN_CONN_TEST=1 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $arg (use --conn-test or --help)"; exit 2 ;;
  esac
done

# ------------------------------------------------------------------ report sink
REPORT_DIR="$SCRIPT_DIR/green-health-reports"
mkdir -p "$REPORT_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPORT_DIR/green-health-$TS.txt"
exec > >(tee "$REPORT") 2>&1   # everything below goes to BOTH stdout and the report file

FAILS=()   # human-readable failing-component strings; empty => healthy verdict
note_fail() { FAILS+=("$1"); }

hr()      { printf '%s\n' "------------------------------------------------------------------------------"; }
section() { echo; echo "=============================================================================="; echo "## $1"; echo "=============================================================================="; }
sub()     { echo; echo ">> $1"; }
# kpods <ns> <label-selector> : count pods whose STATUS is neither Running nor Completed
count_bad_pods() { kubectl -n "$1" get pods -l "$2" --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" && $3!="Succeeded"{c++} END{print c+0}'; }

# ------------------------------------------------------------------ header + guard
echo "=============================================================================="
echo "  GREEN (Talos / cartarch-prod) CLUSTER HEALTH CHECK  —  READ-ONLY DIAGNOSTIC"
echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Report:    $REPORT"
echo "  Mode:      $([ "$RUN_CONN_TEST" -eq 1 ] && echo 'read-only + CONNECTIVITY TEST (creates+deletes 2 pods)' || echo 'pure read-only (use --conn-test for the cross-node pod test)')"
echo "=============================================================================="

CUR_CTX="$(kubectl config current-context 2>/dev/null || true)"
CUR_SRV="$(kubectl config view --minify -o jsonpath='{.clusters[*].cluster.server}' 2>/dev/null || true)"
echo "  KUBECONFIG: $KUBECONFIG"
echo "  Context:    ${CUR_CTX:-<none>}    Server: ${CUR_SRV:-<none>}"
if [[ "$CUR_CTX" != "$EXPECT_CONTEXT" ]]; then
  echo
  echo "  *** ABORT: expected green context '$EXPECT_CONTEXT' but got '${CUR_CTX:-<none>}'."
  echo "  ***        Refusing to run so this never targets the wrong cluster (e.g. blue/k3s)."
  exit 2
fi
if ! kubectl version -o json >/dev/null 2>&1 && ! kubectl get --raw='/readyz' >/dev/null 2>&1; then
  echo
  echo "  *** WARNING: green API server at $CUR_SRV is not responding to read probes."
  echo "  ***          (control plane down / unreachable). Sections below will show errors."
  note_fail "green API server unreachable ($CUR_SRV)"
fi

# ============================================================== 1. NODES
section "1. NODES — all 4 green nodes Ready? versions?"
kubectl get nodes -o wide 2>&1
sub "node conditions (Ready / pressure) + kubelet version"
kubectl get nodes -o custom-columns='NODE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MEMPRESSURE:.status.conditions[?(@.type=="MemoryPressure")].status,DISKPRESSURE:.status.conditions[?(@.type=="DiskPressure")].status,PIDPRESSURE:.status.conditions[?(@.type=="PIDPressure")].status,KUBELET:.status.nodeInfo.kubeletVersion' 2>&1
NODES_TOTAL="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
NODES_NOTREADY="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{c++} END{print c+0}')"
echo
echo "nodes: ${NODES_TOTAL:-0} total, ${NODES_NOTREADY:-0} NOT Ready"
[[ "${NODES_NOTREADY:-0}" -gt 0 ]] && note_fail "${NODES_NOTREADY} node(s) NOT Ready"
[[ "${NODES_TOTAL:-0}" -ne 4 ]] && note_fail "expected 4 green nodes, found ${NODES_TOTAL:-0}"

# ============================================================== 2. CORE NETWORKING PODS
section "2. CORE NETWORKING PODS — flannel / kube-proxy / coredns (status, restarts, node)"
sub "kube-flannel (CNI overlay)"
kubectl -n kube-system get pods -l k8s-app=flannel -o wide 2>&1
sub "kube-proxy (Service/ClusterIP iptables)"
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide 2>&1
sub "coredns (cluster DNS)  [0/1 Completed rows = leftover terminated replicas, not failures]"
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide 2>&1

FLANNEL_BAD="$(count_bad_pods kube-system k8s-app=flannel)"
PROXY_BAD="$(count_bad_pods kube-system k8s-app=kube-proxy)"
COREDNS_RUNNING="$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | awk '$3=="Running"{c++} END{print c+0}')"
echo
echo "flannel not-Running: ${FLANNEL_BAD:-?} | kube-proxy not-Running: ${PROXY_BAD:-?} | coredns Running: ${COREDNS_RUNNING:-?}"
[[ "${FLANNEL_BAD:-1}" -gt 0 ]] && note_fail "${FLANNEL_BAD} kube-flannel pod(s) not Running"
[[ "${PROXY_BAD:-1}" -gt 0 ]] && note_fail "${PROXY_BAD} kube-proxy pod(s) not Running"
[[ "${COREDNS_RUNNING:-0}" -lt 1 ]] && note_fail "no coredns pods Running"

# ============================================================== 3. COREDNS / DNS WIRING
section "3. COREDNS HEALTH — Service, endpoints, recent log errors"
sub "kube-dns Service + endpoints (endpoints empty => DNS Service has no backends)"
kubectl -n kube-system get svc kube-dns -o wide 2>&1
kubectl -n kube-system get endpoints kube-dns 2>&1
DNS_EP="$(kubectl -n kube-system get endpoints kube-dns -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
echo
echo "kube-dns endpoint IPs: ${DNS_EP:-<NONE>}"
[[ -z "$DNS_EP" ]] && note_fail "kube-dns Service has NO endpoints"
sub "recent coredns log lines mentioning error/SERVFAIL/timeout (last 40 lines scanned)"
for p in $(kubectl -n kube-system get pods -l k8s-app=kube-dns --field-selector=status.phase=Running -o name 2>/dev/null); do
  echo "--- $p ---"
  kubectl -n kube-system logs "$p" --tail=40 2>&1 | grep -iE 'error|servfail|timeout|refused|plugin/errors' || echo "(no error lines in last 40)"
done
echo
echo "NOTE: a definitive in-cluster DNS RESOLUTION test requires a pod -> run with --conn-test."

# ============================================================== 4. CROSS-NODE CONNECTIVITY
section "4. CROSS-NODE CONNECTIVITY — the key post-crash diagnostic"
sub "Service under suspicion: $ARGO_APP path = argocd-application-controller (worker1) -> argocd-repo-server Service (cp1)"
kubectl -n argocd get svc argocd-repo-server -o wide 2>&1
kubectl -n argocd get endpoints argocd-repo-server 2>&1
REPO_SVC_IP="$(kubectl -n argocd get svc argocd-repo-server -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
REPO_SVC_PORT="$(kubectl -n argocd get svc argocd-repo-server -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)"
echo
echo "argocd-repo-server Service = ${REPO_SVC_IP:-?}:${REPO_SVC_PORT:-?}"
echo "where the endpoints/controllers actually run:"
kubectl -n argocd get pods -o wide 2>&1 | grep -E 'NAME|repo-server|application-controller' || true

if [[ "$RUN_CONN_TEST" -ne 1 ]]; then
  echo
  echo "  [SKIPPED] The active cross-node pod-to-pod probe is OFF by default (it creates"
  echo "            2 ephemeral test pods). Re-run with --conn-test to execute it."
  echo "            Read-only signals above (flannel Running, Service has endpoints) are"
  echo "            necessary-but-not-sufficient: only the live probe proves packets cross nodes."
else
  echo
  echo "  [CONN-TEST] *** This section CREATES 2 ephemeral pods (busybox on $TEST_NODE_A + $TEST_NODE_B)"
  echo "  [CONN-TEST] *** runs probes between them, then DELETES them. It creates nothing else."
  POD_A="ghc-test-${TEST_NODE_A}"
  POD_B="ghc-test-${TEST_NODE_B}"
  cleanup_testpods() {
    echo; echo ">> [CONN-TEST] cleanup: deleting test pods $POD_A $POD_B"
    kubectl -n "$TEST_NS" delete pod "$POD_A" "$POD_B" --ignore-not-found --grace-period=5 2>&1 || true
  }
  trap cleanup_testpods EXIT
  # idempotent: remove any leftovers from a prior run before recreating
  kubectl -n "$TEST_NS" delete pod "$POD_A" "$POD_B" --ignore-not-found --grace-period=1 >/dev/null 2>&1 || true

  mk_pod() {  # $1=name $2=node ; busybox that serves "healthy" on :8080 and stays up
    cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $TEST_NS
  labels: { app: green-health-check }
spec:
  nodeSelector: { kubernetes.io/hostname: "$2" }
  tolerations:
    - { key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule }
    - { key: node-role.kubernetes.io/master, operator: Exists, effect: NoSchedule }
  terminationGracePeriodSeconds: 2
  containers:
    - name: box
      image: busybox:1.36
      command: ["sh","-c","echo healthy > /tmp/index.html && httpd -f -p 8080 -h /tmp"]
YAML
  }
  echo ">> [CONN-TEST] creating pods"
  { mk_pod "$POD_A" "$TEST_NODE_A"; echo "---"; mk_pod "$POD_B" "$TEST_NODE_B"; } | kubectl apply -f - 2>&1

  echo ">> [CONN-TEST] waiting up to 60s for both pods Ready"
  kubectl -n "$TEST_NS" wait --for=condition=Ready "pod/$POD_A" "pod/$POD_B" --timeout=60s 2>&1
  WAIT_RC=$?
  kubectl -n "$TEST_NS" get pods -l app=green-health-check -o wide 2>&1
  if [[ $WAIT_RC -ne 0 ]]; then
    echo "  *** test pods did not become Ready — describing for diagnosis:"
    kubectl -n "$TEST_NS" describe pod "$POD_A" "$POD_B" 2>&1 | grep -A12 -E 'Events:' || true
    note_fail "cross-node test pods failed to start (see describe) — connectivity UNVERIFIED"
  else
    IP_A="$(kubectl -n "$TEST_NS" get pod "$POD_A" -o jsonpath='{.status.podIP}' 2>/dev/null)"
    IP_B="$(kubectl -n "$TEST_NS" get pod "$POD_B" -o jsonpath='{.status.podIP}' 2>/dev/null)"
    K8S_SVC_IP="$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
    echo "  pod IPs: $POD_A=$IP_A ($TEST_NODE_A)   $POD_B=$IP_B ($TEST_NODE_B)"
    PASS_ALL=1
    probe() {  # $1=label $2..=command run inside POD_A
      local label="$1"; shift
      echo "  -- probe: $label"
      if kubectl -n "$TEST_NS" exec "$POD_A" -- sh -c "$*" 2>&1 | sed 's/^/       /'; then
        echo "     RESULT: PASS"
      else
        echo "     RESULT: FAIL"; PASS_ALL=0
      fi
    }
    echo ">> [CONN-TEST] from $POD_A (on $TEST_NODE_A):"
    probe "L3 ICMP -> $POD_B pod IP across nodes"        "ping -c3 -W2 $IP_B >/dev/null && echo ok"
    probe "L4/L7 HTTP -> $POD_B:8080 across nodes"        "wget -T5 -qO- http://$IP_B:8080/ | grep -q healthy && echo ok"
    probe "Service -> argocd-repo-server ${REPO_SVC_IP}:${REPO_SVC_PORT} (the symptom path)" "nc -w5 ${REPO_SVC_IP} ${REPO_SVC_PORT} </dev/null && echo connected"
    probe "Service -> kubernetes API ${K8S_SVC_IP}:443"  "nc -w5 ${K8S_SVC_IP} 443 </dev/null && echo connected"
    probe "DNS -> kubernetes.default via CoreDNS"         "nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -q Address && echo resolved"
    probe "DNS -> argocd-repo-server.argocd via CoreDNS"  "nslookup argocd-repo-server.argocd.svc.cluster.local 2>&1 | grep -q Address && echo resolved"
    echo ">> [CONN-TEST] reverse direction from $POD_B (on $TEST_NODE_B) -> $POD_A:8080"
    if kubectl -n "$TEST_NS" exec "$POD_B" -- sh -c "wget -T5 -qO- http://$IP_A:8080/ | grep -q healthy && echo ok" 2>&1 | sed 's/^/       /'; then
      echo "     RESULT: PASS"; else echo "     RESULT: FAIL"; PASS_ALL=0; fi
    [[ "$PASS_ALL" -ne 1 ]] && note_fail "cross-node connectivity probe FAILED (see section 4 RESULT lines)"
  fi
  cleanup_testpods
  trap - EXIT
fi

# ============================================================== 5. ARGOCD HEALTH
section "5. ARGOCD HEALTH — pods + the $ARGO_APP app sync/health/operationState"
sub "argocd pods"
kubectl -n argocd get pods -o wide 2>&1
ARGO_BAD="$(kubectl -n argocd get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"{c++} END{print c+0}')"
[[ "${ARGO_BAD:-0}" -gt 0 ]] && note_fail "${ARGO_BAD} argocd pod(s) not Running"

sub "all Argo Applications"
kubectl -n argocd get applications.argoproj.io 2>&1

sub "$ARGO_APP — deep status"
A_SYNC="$(kubectl -n argocd get application "$ARGO_APP" -o jsonpath='{.status.sync.status}' 2>/dev/null)"
A_HEALTH="$(kubectl -n argocd get application "$ARGO_APP" -o jsonpath='{.status.health.status}' 2>/dev/null)"
A_OPMSG="$(kubectl -n argocd get application "$ARGO_APP" -o jsonpath='{.status.operationState.message}' 2>/dev/null)"
A_CONDS="$(kubectl -n argocd get application "$ARGO_APP" -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>/dev/null)"
echo "sync   : ${A_SYNC:-<none>}"
echo "health : ${A_HEALTH:-<none>}"
echo "operationState.message: ${A_OPMSG:-<none>}"
echo "conditions:"
echo "${A_CONDS:-  (none)}"
if echo "$A_CONDS $A_OPMSG" | grep -qiE 'ComparisonError|connection refused|dial tcp|i/o timeout|context deadline'; then
  note_fail "$ARGO_APP shows ComparisonError / connection error (the post-crash networking symptom)"
fi

sub "argocd-application-controller — last 25 log lines mentioning repo-server/refused/error"
for p in $(kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-application-controller -o name 2>/dev/null) \
         $(kubectl -n argocd get pods -o name 2>/dev/null | grep application-controller); do
  echo "--- $p ---"; kubectl -n argocd logs "$p" --tail=25 2>&1 | grep -iE 'repo-server|refused|error|comparison|dial' | tail -15 || echo "(none)"
  break
done

# ============================================================== 6. PLATFORM COMPONENTS
section "6. PLATFORM COMPONENTS — Longhorn / cert-manager / CNPG operator / sealed-secrets"
for entry in \
  "longhorn-system|Longhorn (green storage)" \
  "cert-manager|cert-manager" \
  "cnpg-system|CloudNativePG operator" \
  "sealed-secrets|sealed-secrets"; do
  ns="${entry%%|*}"; label="${entry##*|}"
  sub "$label  (ns: $ns)"
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    echo "(namespace $ns not found)"; note_fail "$label namespace ($ns) missing"; continue
  fi
  kubectl -n "$ns" get pods -o wide 2>&1
  bad="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" && $3!="Succeeded"{c++} END{print c+0}')"
  [[ "${bad:-0}" -gt 0 ]] && note_fail "${bad} not-Running pod(s) in $label ($ns)"
done
sub "Longhorn volumes (green) — robustness/state"
kubectl -n longhorn-system get volumes.longhorn.io 2>&1 | head -30 || echo "(no longhorn volumes CRD/objects)"

# ============================================================== 7. SUMMARY VERDICT
section "7. SUMMARY VERDICT"
echo "Cluster : green / Talos / context $EXPECT_CONTEXT"
echo "Nodes   : ${NODES_TOTAL:-?} total, ${NODES_NOTREADY:-?} not Ready"
echo "Argo $ARGO_APP : sync=${A_SYNC:-?} health=${A_HEALTH:-?}"
echo "Conn-test : $([ "$RUN_CONN_TEST" -eq 1 ] && echo 'RAN (see section 4)' || echo 'NOT RUN (read-only mode; use --conn-test)')"
hr
if [[ "${#FAILS[@]}" -eq 0 ]]; then
  echo "VERDICT: ✅ GREEN APPEARS HEALTHY — no failing components detected by this sweep."
  [[ "$RUN_CONN_TEST" -ne 1 ]] && echo "         (NOTE: cross-node connectivity NOT actively probed — re-run with --conn-test to confirm the symptom path.)"
else
  echo "VERDICT: ❌ GREEN NOT HEALTHY — ${#FAILS[@]} issue(s):"
  for f in "${FAILS[@]}"; do echo "   - $f"; done
fi
hr
echo "Report saved: $REPORT"
echo "Re-run anytime to watch recovery: $0 $*"
echo "This script is DIAGNOSIS ONLY — no remediation is performed. Fixes are attended/manual."
