# Agent-Sandbox Schritt 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** kubernetes-sigs/agent-sandbox v1.0.12 im Lab-Cluster installieren und mit einem abgesicherten Namespace `sandboxes` (Template, Warm Pool, Netzsperren, Admission-Regeln, RBAC) end-to-end testen.

**Architecture:** Alles liegt unter `k8s/agent-sandbox/` als Kustomize-Verzeichnis: das gepinnte Release-Manifest eingecheckt unter `vendor/`, eigene Manifeste unter `manifests/`, installiert mit `kubectl apply --server-side -k k8s/agent-sandbox`. Dazu ein `test.sh`, das gegen den laufenden Cluster prüft und bei Fehlern mit Exit-Code ≠ 0 endet. Beides läuft vom Laptop mit `KUBECONFIG=~/.kube/gcp-sec-lab`. Noch kein Kata: Sandboxes laufen mit `runc` auf `w1`.

**Tech Stack:** Bash, kubectl, agent-sandbox v1.0.12 (CRDs `agents.x-k8s.io/v1beta1`, `extensions.agents.x-k8s.io/v1beta1`), Cilium 1.20 (`cilium.io/v2` CiliumNetworkPolicy, DNS-Proxy aktiv), Kubernetes 1.36 (`ValidatingAdmissionPolicy` v1, Pod Security Admission).

**Spec:** `docs/superpowers/specs/2026-11-22-agent-sandbox-design.md` (Abschnitt "Schritt 1")

## Global Constraints

- agent-sandbox Version `v1.0.12`, Manifest `sandbox-with-extensions.yaml`, SHA-256 `1fe83dff2536a643edf7d001c4585d77155176f6d570204f408159d9ac9d0fe5`.
- URL: `https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.12/sandbox-with-extensions.yaml`, eingecheckt als `k8s/agent-sandbox/vendor/sandbox-with-extensions-v1.0.12.yaml` (Hash beim Einchecken prüfen).
- Namespace der Sandboxes: `sandboxes`. Controller-Namespace (vom Release): `agent-sandbox-system`, Deployment `agent-sandbox-controller`.
- Pod Security: `enforce: baseline`, `warn: restricted` auf `sandboxes`.
- RuntimeClass steht an genau einer Stelle: als Patch in `kustomization.yaml` (in Schritt 1 auskommentiert = kein `runtimeClassName`, runc).
- Template: `networkPolicyManagement: Unmanaged` (die Managed-Default-Policy erlaubt Internet), `automountServiceAccountToken: false`.
- Egress aus `sandboxes`: nur DNS zu kube-dns, nur Namen `*.cluster.local`. Kein Metadata-Server (`169.254.169.254`), kein Internet, keine anderen Pods/Services. Ingress: nichts.
- Claims in `sandboxes` müssen `spec.lifecycle.shutdownTime` und `shutdownPolicy: Delete` haben.
- ServiceAccount `sandbox-orchestrator` in `sandboxes`: nur `sandboxclaims` (create/get/list/watch/delete), `pods` (get/list), `pods/exec` (create).
- Kein Sandbox Router, keine Dashboards, nichts öffentlich exponiert.
- Test-Image: `busybox:1.37` (hat `wget`, `nslookup`, `sleep`).
- Commits ohne AI-Attribution. Branch `feat/agent-sandbox`. PR öffnen, **nicht mergen**.

## Review Focus

- **Claim ohne `shutdownTime`** → muss vom API-Server abgelehnt werden, sonst bleibt die Sandbox ewig. Test in Task 2.
- **Pod in `sandboxes` mit ServiceAccount-Token** (z. B. jemand legt einen normalen Pod an) → abgelehnt. Test in Task 2.
- **DNS-Exfiltration**: `nslookup example.com` aus der Sandbox muss scheitern, `nslookup kubernetes.default.svc.cluster.local` muss klappen. Test in Task 3.
- **Cluster-intern erreichbar**: Verbindung zu `kubernetes.default.svc:443` (API-Server) muss scheitern, obwohl der Name auflösbar ist. Test in Task 3.
- **Zweimal `kubectl apply -k`** → kein Fehler; `kubectl diff -k` danach leer. Test in Task 4.

---

## File Structure

| Datei | Verantwortung |
|---|---|
| `k8s/agent-sandbox/kustomization.yaml` | Fasst Release-Manifest + eigene Manifeste zusammen, RuntimeClass-Patch (auskommentiert) |
| `k8s/agent-sandbox/vendor/sandbox-with-extensions-v1.0.12.yaml` | Release-Manifest, unverändert |
| `k8s/agent-sandbox/test.sh` | Abnahmetests, Abschnitte `controller`, `lifecycle`, `network`, `rbac`, `all` (Default) |
| `k8s/agent-sandbox/manifests/00-namespace.yaml` | Namespace `sandboxes` mit PSA-Labels |
| `k8s/agent-sandbox/manifests/10-network-policy.yaml` | CiliumNetworkPolicy `sandboxes-default` |
| `k8s/agent-sandbox/manifests/20-admission.yaml` | VAPs + Bindings `sandboxes-claim-lifecycle`, `sandboxes-pod-guard` |
| `k8s/agent-sandbox/manifests/30-template.yaml` | `SandboxTemplate` `default` + `SandboxWarmPool` `default` |
| `k8s/agent-sandbox/manifests/40-rbac.yaml` | ServiceAccount, Role, RoleBinding `sandbox-orchestrator` |
| `README.md`, `docs/roadmap.md` | Abschnitt "Sandboxes", Checkboxen |

---

### Task 1: Controller installieren

**Files:**
- Create: `k8s/agent-sandbox/kustomization.yaml`, `k8s/agent-sandbox/vendor/sandbox-with-extensions-v1.0.12.yaml`, `k8s/agent-sandbox/test.sh`

**Interfaces:**
- Produces: `kustomization.yaml` mit `resources:` (vendor-Datei, dann `manifests/*.yaml`, die spätere Tasks dort eintragen). `test.sh [controller|lifecycle|network|rbac|all]`, Helfer in `test.sh`: `pass <msg>`, `fail <msg>` (merkt Fehler, Exit 1 am Ende), `expect_ok <msg> -- <cmd...>`, `expect_fail <msg> -- <cmd...>`.

- [ ] **Step 1: `test.sh` mit Abschnitt `controller` schreiben**

Prüft:
- `kubectl get crd sandboxes.agents.x-k8s.io sandboxtemplates.extensions.agents.x-k8s.io sandboxclaims.extensions.agents.x-k8s.io sandboxwarmpools.extensions.agents.x-k8s.io` → ok
- `kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=90s` → ok
- Image des Controllers enthält `v1.0.12`

`set -euo pipefail`, bricht ab, wenn `KUBECONFIG` nicht gesetzt ist.

- [ ] **Step 2: Test laufen lassen, muss fehlschlagen**

Run: `KUBECONFIG=~/.kube/gcp-sec-lab k8s/agent-sandbox/test.sh controller`
Expected: FAIL bei den CRDs, Exit-Code 1.

- [ ] **Step 3: Release einchecken und `kustomization.yaml` schreiben**

Manifest herunterladen, SHA-256 gegen Global Constraints prüfen, unverändert nach `vendor/` legen. `kustomization.yaml` mit `resources: [vendor/sandbox-with-extensions-v1.0.12.yaml]` und einem auskommentierten JSON6902-Patch auf `SandboxTemplate/default` (`/spec/podTemplate/spec/runtimeClassName`) als Platzhalter für Schritt 3.

- [ ] **Step 4: Installieren und Test grün**

Run: `export KUBECONFIG=~/.kube/gcp-sec-lab; kubectl apply --server-side -k k8s/agent-sandbox && k8s/agent-sandbox/test.sh controller`
Expected: alle `pass`, Exit 0.

- [ ] **Step 5: Commit**

```bash
git add k8s/agent-sandbox
git commit -m "Install agent-sandbox v1.0.12 controller"
```

---

### Task 2: Namespace, Template, Warm Pool, Admission-Regeln, Lifecycle

**Files:**
- Create: `k8s/agent-sandbox/manifests/00-namespace.yaml`, `20-admission.yaml`, `30-template.yaml`
- Modify: `k8s/agent-sandbox/test.sh` (Abschnitt `lifecycle`)

**Interfaces:**
- Consumes: `kustomization.yaml` (neue Dateien unter `resources:` eintragen), Helfer aus `test.sh` (Task 1).
- Produces: `SandboxTemplate/default`, `SandboxWarmPool/default` (`replicas: 1`) in `sandboxes`; Pods des Templates tragen Label `app.kubernetes.io/part-of: agent-sandbox` (für Policy-Selektoren in Task 3). Testhelfer `new_claim <name> <seconds-until-shutdown>` (legt Claim an, wartet bis Ready, gibt Pod-Namen aus; Pod-Name aus dem Sandbox-Status bzw. Pod-Label ermitteln) und `cleanup_claims` (per `trap` am Ende).

- [ ] **Step 1: Abschnitt `lifecycle` in `test.sh` schreiben**

Prüft:
- Namespace `sandboxes` hat `pod-security.kubernetes.io/enforce=baseline`.
- WarmPool `default` hat `readyReplicas >= 1` (warten bis 120 s).
- `new_claim t-life 600` → Claim Ready, `kubectl exec <pod> -- echo hello` gibt `hello` aus.
- Pod hat **kein** `runtimeClassName` (Schritt 1) und `automountServiceAccountToken=false`; `kubectl exec <pod> -- ls /var/run/secrets/kubernetes.io/serviceaccount` scheitert.
- `kubectl delete sandboxclaim t-life` → Pod verschwindet innerhalb 60 s.
- `new_claim t-exp 45` → nach spätestens 120 s existieren Claim und Pod nicht mehr.
- expect_fail: Claim ohne `spec.lifecycle` anlegen.
- expect_fail: Claim mit `shutdownPolicy: Retain` anlegen.
- expect_fail: `kubectl -n sandboxes run t-plain --image=busybox:1.37 -- sleep 60` (Token wird gemountet).

- [ ] **Step 2: Test laufen lassen, muss fehlschlagen**

Run: `KUBECONFIG=~/.kube/gcp-sec-lab k8s/agent-sandbox/test.sh lifecycle`
Expected: FAIL beim Namespace.

- [ ] **Step 3: Manifeste schreiben**

- `00-namespace.yaml`: Namespace `sandboxes`, Labels `pod-security.kubernetes.io/enforce: baseline`, `pod-security.kubernetes.io/enforce-version: latest`, `pod-security.kubernetes.io/warn: restricted`.
- `20-admission.yaml`:
  - VAP `sandboxes-claim-lifecycle` auf `extensions.agents.x-k8s.io/v1beta1 sandboxclaims` CREATE/UPDATE; Bedingungen: `has(object.spec.lifecycle) && has(object.spec.lifecycle.shutdownTime)` und `object.spec.lifecycle.shutdownPolicy in ['Delete','DeleteForeground']`.
  - VAP `sandboxes-pod-guard` auf `pods` CREATE; Bedingung: `has(object.spec.automountServiceAccountToken) && object.spec.automountServiceAccountToken == false`. (Schritt 3 ergänzt hier die RuntimeClass-Bedingung.)
  - Je ein Binding mit `validationActions: [Deny]` und `matchResources.namespaceSelector` auf `kubernetes.io/metadata.name: sandboxes`.
- `30-template.yaml`: `SandboxTemplate default` mit `networkPolicyManagement: Unmanaged`, `podTemplate`: Label `app.kubernetes.io/part-of: agent-sandbox`, `automountServiceAccountToken: false`, ein Container `sandbox`, `busybox:1.37`, `command: ["sleep","infinity"]`, Requests `50m/64Mi`, Limits `500m/256Mi`. `SandboxWarmPool default` mit `sandboxTemplateRef.name: default`, `replicas: 1`.

- [ ] **Step 4: Installieren und Test grün**

Run: `kubectl apply --server-side -k k8s/agent-sandbox && k8s/agent-sandbox/test.sh lifecycle`
Expected: alle `pass`, Exit 0. Falls der Controller-Pod der Warm-Pool-Sandbox an der Pod-Guard-Regel scheitert, die Regel nicht lockern, sondern das Template korrigieren.

- [ ] **Step 5: Commit**

```bash
git add k8s/agent-sandbox
git commit -m "Add sandboxes namespace, template, warm pool and admission rules"
```

---

### Task 3: Netzwerk-Absicherung

**Files:**
- Create: `k8s/agent-sandbox/manifests/10-network-policy.yaml`
- Modify: `k8s/agent-sandbox/test.sh` (Abschnitt `network`)

**Interfaces:**
- Consumes: `new_claim`, `cleanup_claims` (Task 2), Label `app.kubernetes.io/part-of: agent-sandbox`.

- [ ] **Step 1: Abschnitt `network` in `test.sh` schreiben**

Mit `new_claim t-net 600`, alle Befehle per `kubectl exec` mit Timeout 5 s:
- expect_ok: `nslookup kubernetes.default.svc.cluster.local`
- expect_fail: `nslookup example.com`
- expect_fail: `wget -q -T 5 -O- --header Metadata-Flavor:Google http://169.254.169.254/computeMetadata/v1/`
- expect_fail: `wget -q -T 5 -O- http://1.1.1.1`
- expect_fail: `nc -z -w 5 kubernetes.default.svc 443` (Name auflösbar, Verbindung muss scheitern)
- expect_fail: `nc -z -w 5 <Pod-IP von hubble-relay in kube-system> 4245`
- expect_fail (Ingress): In der Sandbox Listener starten (`sh -c 'nohup nc -lk -p 8080 -e echo ok >/dev/null 2>&1 &'`), dann aus einem Probe-Pod (`busybox:1.37`) im Test-Namespace `sandbox-probe` (wird im Test angelegt und gelöscht) `nc -w 5 <Sandbox-Pod-IP> 8080`. Gegenprobe vor dem Policy-Apply ist nicht nötig; der Listener wird per `expect_ok` innerhalb der Sandbox selbst geprüft (`nc -w 2 127.0.0.1 8080`).

- [ ] **Step 2: Test laufen lassen, muss fehlschlagen**

Run: `k8s/agent-sandbox/test.sh network`
Expected: FAIL bei `nslookup example.com` / Metadata / Internet (heute ist alles offen).

- [ ] **Step 3: `10-network-policy.yaml` schreiben**

CiliumNetworkPolicy `sandboxes-default` in `sandboxes`, `endpointSelector: {}` (alle Pods im Namespace), `enableDefaultDeny: {ingress: true, egress: true}`, **keine** Ingress-Regel (nie `ingress: [{}]`, das erlaubt alles). Egress genau eine Regel: `toEndpoints` mit `k8s:io.kubernetes.pod.namespace: kube-system`, `k8s:k8s-app: kube-dns`, Ports 53/UDP und 53/TCP, `rules.dns: [{matchPattern: "*.cluster.local"}]`.

- [ ] **Step 4: Anwenden und Test grün**

Run: `kubectl apply --server-side -k k8s/agent-sandbox && k8s/agent-sandbox/test.sh network && k8s/agent-sandbox/test.sh lifecycle`
Expected: beide Abschnitte grün. Mit `hubble observe -n sandboxes --verdict DROPPED` (auf der Control Plane) sind die blockierten Versuche sichtbar.

- [ ] **Step 5: Commit**

```bash
git add k8s/agent-sandbox
git commit -m "Lock down sandbox network: no ingress, cluster-only DNS egress"
```

---

### Task 4: RBAC für den Orchestrator

**Files:**
- Create: `k8s/agent-sandbox/manifests/40-rbac.yaml`
- Modify: `k8s/agent-sandbox/test.sh` (Abschnitt `rbac`)

**Interfaces:**
- Produces: ServiceAccount `sandboxes/sandbox-orchestrator` (wird vom Orchestrator in Phase 5 genutzt).

- [ ] **Step 1: Abschnitt `rbac` schreiben**

Mit `kubectl auth can-i --as=system:serviceaccount:sandboxes:sandbox-orchestrator -n sandboxes`:
- yes: `create sandboxclaims.extensions.agents.x-k8s.io`, `delete sandboxclaims.extensions.agents.x-k8s.io`, `create pods/exec`, `list pods`
- no: `get secrets`, `create pods`, `update sandboxtemplates.extensions.agents.x-k8s.io`, `delete ciliumnetworkpolicies.cilium.io`, `create sandboxclaims.extensions.agents.x-k8s.io -n default`

- [ ] **Step 2: Test laufen lassen, muss fehlschlagen**

Run: `k8s/agent-sandbox/test.sh rbac`
Expected: FAIL bei `create sandboxclaims`.

- [ ] **Step 3: `40-rbac.yaml` schreiben** (ServiceAccount mit `automountServiceAccountToken: false`, Role + RoleBinding gemäss Global Constraints).

- [ ] **Step 4: Alles grün, Idempotenz**

Run: `kubectl apply --server-side -k k8s/agent-sandbox && kubectl diff -k k8s/agent-sandbox; k8s/agent-sandbox/test.sh`
Expected: alle Abschnitte grün, Exit 0.

- [ ] **Step 5: Commit**

```bash
git add k8s/agent-sandbox
git commit -m "Add sandbox-orchestrator service account with minimal RBAC"
```

---

### Task 5: Doku und PR

**Files:**
- Modify: `README.md` (neuer Abschnitt "Sandboxes" vor "Notes"), `docs/roadmap.md`

- [ ] **Step 1: README-Abschnitt "Sandboxes"** (englisch wie der Rest der README): was installiert wird, `kubectl apply --server-side -k k8s/agent-sandbox` und `test.sh`, Kette Template → WarmPool → Claim mit Beispiel-Claim (inkl. `shutdownTime`), was gesperrt ist, Hinweis "bis Schritt 3 kein Kata: kein fremder Code in Sandboxes", RuntimeClass-Patch in `kustomization.yaml`.

- [ ] **Step 2: Roadmap Phase 3 abhaken:** "Agent Sandbox Controller und CRDs installieren", "Sandbox Templates konfigurieren", "Sandbox-Lifecycle (Create, Execute, Delete) testen", "Automatische Bereinigung und Timeouts einrichten", "Network Policies und RBAC konfigurieren". Nicht abhaken: "Dynamische Sandbox-Erstellung implementieren" (braucht Orchestrator).

- [ ] **Step 3: Gesamttest**

Run: `k8s/agent-sandbox/test.sh`
Expected: Exit 0.

- [ ] **Step 4: Commit, Push, PR**

```bash
git add README.md docs/roadmap.md docs/superpowers
git commit -m "Document agent-sandbox setup"
git push -u origin feat/agent-sandbox
gh pr create --base main --title "Install and lock down agent-sandbox (step 1)" --body "<Zusammenfassung, Testausgabe>"
```
Nicht mergen.
