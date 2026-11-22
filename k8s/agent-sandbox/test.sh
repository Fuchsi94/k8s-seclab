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

main() {
  local section=${1:-all}
  case $section in
    controller) test_controller ;;
    all) test_controller ;;
    *) echo "unknown section: $section" >&2; exit 2 ;;
  esac
  if [[ $FAILED -ne 0 ]]; then echo "FAILED"; exit 1; fi
  echo "OK"
}

main "$@"
