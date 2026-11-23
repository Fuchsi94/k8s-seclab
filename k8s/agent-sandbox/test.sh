#!/usr/bin/env bash
# Acceptance tests for the agent-sandbox setup. Runs against the live cluster.
#
#   export KUBECONFIG=~/.kube/gcp-sec-lab
#   k8s/agent-sandbox/test.sh [controller|lifecycle|network|rbac|all]
#
# Exits 1 if any check failed.
set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the lab kubeconfig, e.g. ~/.kube/gcp-sec-lab}"

NS=sandboxes
FAILED=0

pass() { printf '  \033[32mpass\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }

# expect_ok <msg> -- <cmd...>: passes if the command succeeds.
expect_ok() {
  local msg=$1; shift; [[ ${1:-} == -- ]] && shift
  if "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi
}

# expect_fail <msg> -- <cmd...>: passes if the command fails.
expect_fail() {
  local msg=$1; shift; [[ ${1:-} == -- ]] && shift
  if "$@" >/dev/null 2>&1; then fail "$msg"; else pass "$msg"; fi
}

# expect_denied <msg> <policy> -- <cmd...>: passes only if the command fails
# because ValidatingAdmissionPolicy <policy> denied it.
expect_denied() {
  local msg=$1 policy=$2; shift 2; [[ ${1:-} == -- ]] && shift
  local err
  if err=$("$@" 2>&1); then fail "$msg (was accepted)"; return; fi
  if [[ $err == *"ValidatingAdmissionPolicy '$policy'"*"denied request"* ]]; then pass "$msg"
  else fail "$msg (failed for another reason: ${err//$'\n'/ })"; fi
}

test_controller() {
  echo "controller"
  expect_ok "CRDs installed" -- kubectl get crd \
    sandboxes.agents.x-k8s.io \
    sandboxtemplates.extensions.agents.x-k8s.io \
    sandboxclaims.extensions.agents.x-k8s.io \
    sandboxwarmpools.extensions.agents.x-k8s.io
  expect_ok "controller rolled out" -- kubectl -n agent-sandbox-system \
    rollout status deploy/agent-sandbox-controller --timeout=90s
  local image
  image=$(kubectl -n agent-sandbox-system get deploy agent-sandbox-controller \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  if [[ $image == *v1.0.12* ]]; then pass "controller image is v1.0.12"; else fail "controller image is v1.0.12 (got '${image}')"; fi
}

CLAIMS=()

# shutdown_in <seconds>: RFC3339 UTC timestamp <seconds> from now.
shutdown_in() {
  if date -v+1S >/dev/null 2>&1; then date -u -v+"$1"S +%Y-%m-%dT%H:%M:%SZ
  else date -u -d "+$1 seconds" +%Y-%m-%dT%H:%M:%SZ; fi
}

# claim_yaml <name> <lifecycle-yaml-or-empty>: SandboxClaim manifest on the default pool.
claim_yaml() {
  cat <<EOF
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: $1
  namespace: $NS
spec:
  warmPoolRef:
    name: default
$2
EOF
}

# claim_pod <claim>: name of the pod behind a claim (empty if none).
claim_pod() {
  local sb sel
  sb=$(kubectl -n "$NS" get sandboxclaim "$1" -o jsonpath='{.status.sandbox.name}' 2>/dev/null) || return 0
  [[ -n $sb ]] || return 0
  sel=$(kubectl -n "$NS" get sandbox "$sb" -o jsonpath='{.status.selector}' 2>/dev/null) || return 0
  [[ -n $sel ]] || return 0
  kubectl -n "$NS" get pod -l "$sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# new_claim <name> <seconds-until-shutdown>: create claim, wait until Ready, print pod name.
new_claim() {
  local name=$1 secs=$2 pod
  claim_yaml "$name" "  lifecycle:
    shutdownTime: \"$(shutdown_in "$secs")\"
    shutdownPolicy: Delete" | kubectl apply -f - >/dev/null
  CLAIMS+=("$name")
  kubectl -n "$NS" wait sandboxclaim/"$name" --for=condition=Ready --timeout=120s >/dev/null
  for _ in $(seq 1 30); do
    pod=$(claim_pod "$name")
    [[ -n $pod ]] && { echo "$pod"; return 0; }
    sleep 2
  done
  return 1
}

cleanup_claims() {
  for c in "${CLAIMS[@]+"${CLAIMS[@]}"}"; do
    kubectl -n "$NS" delete sandboxclaim "$c" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  kubectl -n "$NS" delete pod t-plain --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete ns sandbox-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup_claims EXIT

# gone_within <seconds> <kind/name>: true once the object no longer exists.
gone_within() {
  local secs=$1 obj=$2
  for _ in $(seq 1 "$secs"); do
    kubectl -n "$NS" get "$obj" >/dev/null 2>&1 || return 0
    sleep 1
  done
  return 1
}

test_lifecycle() {
  echo "lifecycle"
  local psa
  psa=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)
  if [[ $psa == baseline ]]; then pass "namespace enforces PSA baseline"; else fail "namespace enforces PSA baseline (got '${psa}')"; fi

  local ready=0
  for _ in $(seq 1 60); do
    ready=$(kubectl -n "$NS" get sandboxwarmpool default -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    [[ ${ready:-0} -ge 1 ]] && break
    sleep 2
  done
  if [[ ${ready:-0} -ge 1 ]]; then pass "warm pool has a ready sandbox"; else fail "warm pool has a ready sandbox"; fi

  local pod
  if pod=$(new_claim t-life 600); then
    pass "claim t-life is ready (pod $pod)"
    local out
    out=$(kubectl -n "$NS" exec "$pod" -- echo hello 2>/dev/null || true)
    if [[ $out == hello ]]; then pass "exec in sandbox works"; else fail "exec in sandbox works (got '${out}')"; fi
    local rc
    rc=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.runtimeClassName}')
    if [[ -z $rc ]]; then pass "no runtimeClassName yet (step 1)"; else fail "no runtimeClassName yet (got '$rc')"; fi
    expect_ok "automountServiceAccountToken is false" -- \
      test "$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.automountServiceAccountToken}')" = false
    expect_fail "no service account token in sandbox" -- \
      kubectl -n "$NS" exec "$pod" -- ls /var/run/secrets/kubernetes.io/serviceaccount
    kubectl -n "$NS" delete sandboxclaim t-life --wait=false >/dev/null
    expect_ok "deleting the claim removes the pod" -- gone_within 60 "pod/$pod"
  else
    fail "claim t-life is ready"
  fi

  if pod=$(new_claim t-exp 45); then
    expect_ok "claim expires after shutdownTime" -- gone_within 120 sandboxclaim/t-exp
    expect_ok "expired claim's pod is gone" -- gone_within 30 "pod/$pod"
  else
    fail "claim t-exp is ready"
  fi

  expect_denied "claim without lifecycle is rejected" sandboxes-claim-lifecycle -- \
    kubectl apply -f <(claim_yaml t-nolife "")
  expect_denied "claim with shutdownPolicy Retain is rejected" sandboxes-claim-lifecycle -- \
    kubectl apply -f <(claim_yaml t-retain "  lifecycle:
    shutdownTime: \"$(shutdown_in 600)\"
    shutdownPolicy: Retain")
  CLAIMS+=(t-nolife t-retain)
  expect_denied "plain pod with service account token is rejected" sandboxes-pod-guard -- \
    kubectl -n "$NS" run t-plain --image=busybox:1.37 --restart=Never -- sleep 60
}

# sx <pod> <cmd...>: run a command in a sandbox pod, capped at 10 seconds.
sx() { local pod=$1; shift; kubectl -n "$NS" exec "$pod" -- timeout 10 "$@"; }

# gets_ok <probe-ns> <probe-pod> <ip>: true if <ip>:8080 answers "ok".
gets_ok() {
  local out
  out=$(kubectl -n "$1" exec "$2" -- timeout 10 sh -c "nc -w 5 $3 8080 </dev/null" 2>/dev/null || true)
  [[ $out == *ok* ]]
}

test_network() {
  echo "network"
  local pod
  if ! pod=$(new_claim t-net 600); then fail "claim t-net is ready"; return; fi

  expect_ok   "DNS: cluster name resolves" -- sx "$pod" nslookup kubernetes.default.svc.cluster.local
  expect_fail "DNS: external name is refused" -- sx "$pod" nslookup example.com
  expect_fail "egress: GCE metadata server blocked" -- \
    sx "$pod" wget -q -T 5 -O- --header 'Metadata-Flavor: Google' http://169.254.169.254/computeMetadata/v1/
  expect_fail "egress: internet blocked" -- sx "$pod" wget -q -T 5 -O- http://1.1.1.1
  expect_fail "egress: API server blocked" -- sx "$pod" sh -c 'nc -w 5 kubernetes.default.svc 443 </dev/null'
  local relay
  relay=$(kubectl -n kube-system get pod -l k8s-app=hubble-relay -o jsonpath='{.items[0].status.podIP}')
  expect_fail "egress: other pods blocked (hubble-relay $relay)" -- sx "$pod" sh -c "nc -w 5 $relay 4245 </dev/null"

  # Ingress: listener inside the sandbox, probe from another namespace.
  kubectl -n "$NS" exec "$pod" -- sh -c 'nohup nc -lk -p 8080 -e echo ok >/dev/null 2>&1 &' >/dev/null 2>&1
  expect_ok "listener answers inside the sandbox" -- gets_ok "$NS" "$pod" 127.0.0.1
  kubectl create ns sandbox-probe >/dev/null 2>&1 || true
  kubectl -n sandbox-probe run probe --image=busybox:1.37 --restart=Never -- sleep 600 >/dev/null 2>&1 || true
  kubectl -n sandbox-probe wait pod/probe --for=condition=Ready --timeout=90s >/dev/null
  local ip
  ip=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')
  expect_fail "ingress: sandbox not reachable from other pods" -- gets_ok sandbox-probe probe "$ip"
  kubectl delete ns sandbox-probe --wait=false >/dev/null 2>&1 || true
}

main() {
  local section=${1:-all}
  case $section in
    controller) test_controller ;;
    lifecycle) test_lifecycle ;;
    network) test_network ;;
    all) test_controller; test_lifecycle; test_network ;;
    *) echo "unknown section: $section" >&2; exit 2 ;;
  esac
  if [[ $FAILED -ne 0 ]]; then echo "FAILED"; exit 1; fi
  echo "OK"
}

main "$@"
