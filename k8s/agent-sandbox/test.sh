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

# Every claim this script creates carries this label; cleanup deletes by label
# (new_claim runs in a subshell, so a bash array would not survive).
TEST_LABEL=app.kubernetes.io/managed-by=agent-sandbox-test

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
  labels:
    ${TEST_LABEL%%=*}: ${TEST_LABEL#*=}
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
  # A leftover claim with the same name would be reused and may expire mid-test.
  kubectl -n "$NS" delete sandboxclaim "$name" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
  claim_yaml "$name" "  lifecycle:
    shutdownTime: \"$(shutdown_in "$secs")\"
    shutdownPolicy: Delete" | kubectl apply -f - >/dev/null
  kubectl -n "$NS" wait sandboxclaim/"$name" --for=condition=Ready --timeout=120s >/dev/null
  for _ in $(seq 1 30); do
    pod=$(claim_pod "$name")
    [[ -n $pod ]] && { echo "$pod"; return 0; }
    sleep 2
  done
  return 1
}

cleanup_claims() {
  kubectl -n "$NS" delete sandboxclaim -l "$TEST_LABEL" --ignore-not-found --wait=false >/dev/null 2>&1 || true
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
    expect_ok "no service account token in sandbox" -- \
      kubectl -n "$NS" exec "$pod" -- sh -c 'test ! -e /var/run/secrets/kubernetes.io/serviceaccount'
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

  # Probe pod outside the sandbox namespace (no policy): positive controls.
  kubectl create ns sandbox-probe >/dev/null 2>&1 || true
  kubectl -n sandbox-probe run probe --image=busybox:1.37 --restart=Never -- sleep 600 >/dev/null 2>&1 || true
  kubectl -n sandbox-probe wait pod/probe --for=condition=Ready --timeout=90s >/dev/null 2>&1 || fail "probe pod ready"
  local cip cpip
  cip=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
  cpip=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  expect_ok "control: probe outside sandboxes reaches API server $cip:443" -- \
    kubectl -n sandbox-probe exec probe -- timeout 10 sh -c "nc -w 5 $cip 443 </dev/null"

  expect_ok   "DNS: cluster name resolves" -- sx "$pod" nslookup kubernetes.default.svc.cluster.local
  expect_fail "DNS: external name is refused" -- sx "$pod" nslookup example.com
  expect_fail "egress: GCE metadata server blocked" -- \
    sx "$pod" wget -q -T 5 -O- --header 'Metadata-Flavor: Google' http://169.254.169.254/computeMetadata/v1/
  expect_fail "egress: internet blocked" -- sx "$pod" wget -q -T 5 -O- http://1.1.1.1
  expect_fail "egress: API server blocked (service IP $cip:443)" -- sx "$pod" sh -c "nc -w 5 $cip 443 </dev/null"
  expect_fail "egress: API server blocked (node $cpip:6443)" -- sx "$pod" sh -c "nc -w 5 $cpip 6443 </dev/null"
  local relay
  relay=$(kubectl -n kube-system get pod -l k8s-app=hubble-relay -o jsonpath='{.items[0].status.podIP}')
  if [[ -z $relay ]]; then fail "hubble-relay pod IP found"
  else expect_fail "egress: other pods blocked (hubble-relay $relay)" -- sx "$pod" sh -c "nc -w 5 $relay 4245 </dev/null"; fi

  # Ingress: listener inside the sandbox, probe from another namespace.
  kubectl -n "$NS" exec "$pod" -- sh -c 'nohup nc -lk -p 8080 -e echo ok >/dev/null 2>&1 &' >/dev/null 2>&1 || true
  expect_ok "listener answers inside the sandbox" -- gets_ok "$NS" "$pod" 127.0.0.1
  local ip
  ip=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')
  expect_fail "ingress: sandbox not reachable from other pods" -- gets_ok sandbox-probe probe "$ip"
  kubectl delete ns sandbox-probe --wait=false >/dev/null 2>&1 || true
}

test_rbac() {
  echo "rbac"
  local sa=system:serviceaccount:sandboxes:sandbox-orchestrator
  can()    { kubectl auth can-i --as="$sa" -n "${2:-$NS}" $1 >/dev/null 2>&1; }
  local v
  for v in "create sandboxclaims.extensions.agents.x-k8s.io" \
           "delete sandboxclaims.extensions.agents.x-k8s.io" \
           "create pods --subresource=exec" \
           "list pods"; do
    expect_ok "orchestrator may: $v" -- can "$v"
  done
  for v in "get secrets" \
           "create pods" \
           "update sandboxtemplates.extensions.agents.x-k8s.io" \
           "delete ciliumnetworkpolicies.cilium.io"; do
    expect_fail "orchestrator may not: $v" -- can "$v"
  done
  local p
  p=$(kubectl -n "$NS" get pod -l app.kubernetes.io/part-of=agent-sandbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  expect_ok "orchestrator can really exec into a sandbox ($p)" -- \
    kubectl --as="$sa" -n "$NS" exec "$p" -- true
  expect_fail "orchestrator may not: exec into pods in default" -- \
    can "create pods --subresource=exec" default
  expect_fail "orchestrator may not: create sandboxclaims in default" -- \
    can "create sandboxclaims.extensions.agents.x-k8s.io" default
}

# pod_yaml <extra-spec-yaml>: pod in sandboxes with automount off plus extras.
pod_yaml() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: t-guard
  namespace: $NS
spec:
  automountServiceAccountToken: false
$1
  containers:
    - name: c
      image: busybox:1.37
      command: ["sleep", "60"]
EOF
}

# Admission rules and quota, all checks as server-side dry-run (fast, no side effects).
test_guard() {
  echo "guard"
  local life="  lifecycle:
    shutdownTime: \"$(shutdown_in 600)\"
    shutdownPolicy: Delete"
  expect_ok "claim within 24h is accepted (dry-run)" -- \
    kubectl apply --dry-run=server -f <(claim_yaml t-ok "$life")
  expect_denied "claim living longer than 24h is rejected" sandboxes-claim-lifecycle -- \
    kubectl apply --dry-run=server -f <(claim_yaml t-long "  lifecycle:
    shutdownTime: \"$(shutdown_in 90000)\"
    shutdownPolicy: Delete")
  expect_denied "claim with additionalPodMetadata is rejected" sandboxes-claim-fields -- \
    kubectl apply --dry-run=server -f <(claim_yaml t-meta "$life
  additionalPodMetadata:
    annotations:
      io.katacontainers.config.hypervisor.kernel_params: x")
  expect_denied "claim with env is rejected" sandboxes-claim-fields -- \
    kubectl apply --dry-run=server -f <(claim_yaml t-env "$life
  env:
    - name: LD_PRELOAD
      value: /tmp/x.so")
  expect_denied "claim with volumeClaimTemplates is rejected" sandboxes-claim-fields -- \
    kubectl apply --dry-run=server -f <(claim_yaml t-vol "$life
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        volumeName: someone-elses-pv
        resources:
          requests:
            storage: 1Gi")
  expect_denied "pod running as another service account is rejected" sandboxes-pod-guard -- \
    kubectl apply --dry-run=server -f <(pod_yaml "  serviceAccountName: sandbox-orchestrator")
  expect_denied "pod with projected service account token is rejected" sandboxes-pod-guard -- \
    kubectl apply --dry-run=server -f <(pod_yaml "  volumes:
    - name: tok
      projected:
        sources:
          - serviceAccountToken:
              path: token")

  local hard
  hard=$(kubectl -n "$NS" get resourcequota sandboxes -o jsonpath='{.spec.hard.count/sandboxclaims\.extensions\.agents\.x-k8s\.io}' 2>/dev/null || true)
  if [[ $hard == 5 ]]; then pass "quota: at most 5 claims"; else fail "quota: at most 5 claims (got '${hard}')"; fi
  local eph
  eph=$(kubectl -n "$NS" get sandboxtemplate default -o jsonpath='{.spec.podTemplate.spec.containers[0].resources.limits.ephemeral-storage}' 2>/dev/null || true)
  if [[ -n $eph ]]; then pass "template limits ephemeral storage ($eph)"; else fail "template limits ephemeral storage"; fi
}

main() {
  local section=${1:-all}
  case $section in
    controller) test_controller ;;
    lifecycle) test_lifecycle ;;
    network) test_network ;;
    rbac) test_rbac ;;
    guard) test_guard ;;
    all) test_controller; test_guard; test_lifecycle; test_network; test_rbac ;;
    *) echo "unknown section: $section" >&2; exit 2 ;;
  esac
  if [[ $FAILED -ne 0 ]]; then echo "FAILED"; exit 1; fi
  echo "OK"
}

main "$@"
