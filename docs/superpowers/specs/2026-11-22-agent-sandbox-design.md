# Design: Agent-Sandbox, Observability und Kata

Stand: 2026-11-22 · Roadmap: Phase 1 (Rest), 2, 3, Teile von 6

## Warum

Der Security-Agent führt Befehle aus, die ein LLM erzeugt hat (nmap, nuclei,
Shell-Befehle, ...). Dieser Code ist nicht vertrauenswürdig und soll in einer
eigenen MicroVM laufen, damit ein Ausbruch nicht den Node oder den Cluster
erreicht. Sandboxes sollen dynamisch erstellt, benutzt und gelöscht werden
(kubernetes-sigs/agent-sandbox). Ausserdem soll nachvollziehbar sein, was das
Modell ausgibt und was der Agent tut.

Das Modell selbst führt keinen Code aus, es erzeugt nur Text. Deshalb gehört
nur der Agent in die Sandbox; das Modell läuft später (Phase 5) in einem
normalen, gehärteten Pod auf einem GPU-Node. Eine GPU-Variante der Sandbox
braucht es nicht.

## Endziel (vom Nutzer, 2026-11-22)

Interne Ressourcen auf Sicherheitslücken und Leaks prüfen, als Teil der
ISO-27001-Arbeit:

- Code-Scans der eigenen Repos.
- Die per Terraform verwalteten GCP-Ressourcen.
- Die laufende Cloud-Infrastruktur, u. a. die eigene Zeiterfassung (sensible
  Mitarbeiterdaten) und Demo-Applikationen wie eine Agent-Plattform.

Dafür sollen Security-Review-Skills (z. B. cloudflare/security-audit-skill)
mit einem selbst gehosteten, abliterierten Modell laufen. Grund: Mit
Claude Code oder Codex greifen bei tiefen Reviews die Guardrails. Weil
das Modell keine Guardrails hat und der Agent Zugriff auf sensible Systeme
bekommt, muss der Cluster lückenlos überwacht und nachvollziehbar sein.

Folgen für dieses Design:

- Die Leitplanken liegen im Harness und in der Infrastruktur, nicht im
  Modell: read-only Zugangsdaten, Egress nur zu freigegebenen Zielen,
  Freigabe durch einen Menschen vor aktiven Scans gegen laufende Systeme.
- Inhalte aus gescannten Repos und Apps können Anweisungen an das Modell
  enthalten (Prompt Injection); ein Modell ohne Guardrails folgt ihnen eher.
  Deshalb dürfen die Werkzeuge des Agents nichts verändern können.
- Die Aufzeichnung (Schritt 2) dient voraussichtlich auch als Nachweis für
  ISO 27001; siehe offene Entscheidungen.

## Reihenfolge (vom Nutzer festgelegt)

1. **agent-sandbox installieren und testen** (auf den bestehenden Nodes, noch
   ohne Kata).
2. **Observability und Tracing mit Dashboard** (OpenTelemetry, Jaeger, Falco).
3. **Container-Runtime**: dedizierter Sandbox-Node mit Kata.

Jeder Schritt ist ein eigener PR. Kein Merge durch den Agent.

Konsequenz von Schritt 1 vor Schritt 3: Test-Sandboxes laufen bis Schritt 3 als
normale `runc`-Container auf `w1`. Darin läuft bis dahin kein fremder oder
LLM-generierter Code.

## Constraints (alle Schritte)

- Cluster: GCE, kubeadm, Kubernetes 1.36, containerd 2.x, Cilium 1.20 mit
  Hubble, Ubuntu 24.04. Control Plane und `w1` sind `e2-medium` (2 vCPU, 4 GB).
- Bootstrap der Nodes über `scripts/install-common.sh` (Startup-Script,
  idempotent). Cluster-Add-ons dieses Designs kommen **nicht** dorthin,
  sondern als Manifeste/Helm-Values unter `k8s/<komponente>/` plus je ein
  Kustomize-Verzeichnis (`kubectl apply -k`), das vom Laptop mit der Lab-kubeconfig läuft.
  *Meine Entscheidung:* Node-Bootstrap bleibt schlank, Add-ons lassen sich
  schnell iterieren.
- Alle Versionen gepinnt.
- Zugriff von aussen nur über `allowed_ips` (SSH, 6443). Dashboards werden
  nicht öffentlich exponiert, Zugriff per `kubectl port-forward`.

## Schritt 1: agent-sandbox

### Voraussetzungen (laut Projekt-Doku, v1.0.12 vom 2026-11-20)

k8s ≥ 1.29 empfohlen (wir: 1.36), CRD-CEL-Validierung (Standard), kubectl.
Keine bestimmte Runtime nötig; Isolation kommt über die RuntimeClass.

### Ziele

- Controller + CRDs aus gepinntem Release (`sandbox-with-extensions.yaml`:
  `Sandbox` + `SandboxTemplate`, `SandboxClaim`, `SandboxWarmPool`).
  *Meine Entscheidung:* mit Extensions, weil der Orchestrator später
  Sandboxes über Claims aus Templates anfordert.
- Namespace `sandboxes` mit einem `SandboxTemplate`. Der RuntimeClass-Name ist
  ein Kustomize-Patch an einer Stelle, in Schritt 1 leer (= runc),
  in Schritt 3 `kata-clh`.
- Maximale Lebensdauer für Sandboxes (`shutdownTime` o. ä. der API), damit
  vergessene Sandboxes verschwinden. *Meine Entscheidung.*
- ServiceAccount `sandbox-orchestrator` mit Role in `sandboxes`: nur Claims
  erstellen/lesen/löschen und `pods/exec`. *Meine Entscheidung.*
- Grundabsicherung `sandboxes` (*meine Entscheidung*, kostet wenig und gilt
  dann schon ab Schritt 1):
  - Ingress standardmässig gesperrt.
  - Egress nur DNS, und nur für clusterinterne Namen (Cilium-DNS-Regel),
    sonst wäre DNS ein Kanal nach draussen. Externe Ziele kommen mit Phase 6.
  - GCE-Metadata-Server `169.254.169.254` gesperrt (dort liegt das
    kubeadm-Join-Token).
  - `automountServiceAccountToken: false` im Template.
  - Pod Security Admission: **offen, siehe "Offene Entscheidungen"**.
- API-Details v1.0.12 (beim Planen geprüft):
  - Ein `SandboxClaim` verweist nicht auf ein Template, sondern zwingend auf
    einen `SandboxWarmPool` (`spec.warmPoolRef`), der auf das Template zeigt.
    Kette: Template → WarmPool → Claim.
  - Lebensdauer sitzt am Claim: `spec.lifecycle.shutdownTime` (absolut) und
    `shutdownPolicy: Delete`. Ohne `shutdownTime` läuft ein Claim nie ab;
    deshalb erzwingt eine `ValidatingAdmissionPolicy` in `sandboxes`, dass
    jeder Claim eine `shutdownTime` und `shutdownPolicy: Delete` hat.
  - Ohne Angabe legt der Controller pro Template eine NetworkPolicy an, die
    Egress ins **öffentliche Internet erlaubt**. Deshalb
    `networkPolicyManagement: Unmanaged`; die Absicherung macht unsere
    eigene CiliumNetworkPolicy.
- Sandbox Router (für SDK-Clients) wird **nicht** installiert; die
  Standard-Anleitung betreibt ihn ohne Authentifizierung. Kommt mit dem
  Orchestrator.

### Abnahme

- Controller läuft, CRDs vorhanden.
- `SandboxClaim` aus dem Template → Sandbox + Pod entstehen → Befehl per
  `kubectl exec` → Claim löschen → Sandbox und Pod verschwinden.
- Eine Sandbox mit kurzer Lebensdauer verschwindet von selbst.
- Aus der Sandbox schlagen fehl: Metadata-Server, Internet, ein anderer Pod,
  Auflösung eines externen Namens. Auflösung eines Cluster-Namens klappt.
- Der ServiceAccount kann Claims anlegen, aber z. B. keine Secrets lesen.

## Schritt 2: Observability und Tracing (Grobdesign, Details vor Schritt 2)

- **OpenTelemetry Collector** im Cluster als zentraler Eingang (OTLP).
- **Jaeger** (v2) als Trace-Backend und Dashboard, Lab-Speicher (Badger),
  Zugriff per Port-Forward.
- **Falco** (modern eBPF) auf allen Nodes, mit **k8saudit-Plugin**; dafür wird
  das Kubernetes-Audit-Log auf dem API-Server aktiviert (Sandbox-/Claim-
  Ressourcen, `pods/exec`, Änderungen an Policies). Alarme über
  Falcosidekick per OTLP in den Collector.
- **Span-Schema** für Agent-Läufe vorbereitet und dokumentiert
  (`agent.run` → `llm.chat` mit GenAI-Konventionen → `tool.<name>` mit
  Befehl, Sandbox, Exit-Code). Echte Agent-Traces kommen mit dem Orchestrator;
  vLLM kann später selbst per `--otlp-traces-endpoint` senden.
- Hubble bleibt für Netzwerkflüsse.
- **Kosten und Auffälligkeiten (Nutzer, 2026-11-22):** Erst lokale Modelle,
  später Frontier-Modelle per API (Abrechnung pro Token). Deshalb:
  - Token-Verbrauch und Modell pro `llm.chat`-Span (GenAI-Konventionen
    `gen_ai.usage.input_tokens`/`output_tokens`, `gen_ai.request.model`).
  - OTel Collector erzeugt aus den Spans Metriken (spanmetrics) →
    **Prometheus**, Regeln → **Alertmanager** (beides CNCF; Phase 6 der
    Roadmap zieht damit vor). Jaeger selbst kann nicht alarmieren.
  - Alarme (Startwerte, später justieren): Tokens/Kosten pro Lauf und pro
    Tag über Budget; ungewöhnlich viele Tool-Aufrufe oder Wiederholungen
    desselben Aufrufs (Schleife); Lauf dauert zu lange; Falco-Alarm aus einer
    Sandbox; von Cilium blockierter Egress aus `sandboxes`.
  - Alarme melden nur. Harte Budget-Grenzen gehören in ein LLM-Gateway vor
    den Modellen (z. B. Envoy AI Gateway), das kommt mit dem Orchestrator
    (Phase 5), ebenso wie die Umschaltung lokal ↔ Frontier.
- Abnahme: Test-Trace sichtbar in Jaeger; `kubectl exec` in eine Sandbox
  erzeugt einen Falco-Alarm, der ebenfalls ankommt.
- Ziel ist Nachvollziehen/Debuggen, kein manipulationssicherer Nachweis
  (Nutzer, 2026-11-22). Lab-Speicher reicht. Welche Metriken für die
  ISO-27001-Zertifizierung nötig sind, klärt der Nutzer mit seinem Chef;
  das kann später persistenten Speicher und Aufbewahrungsfristen nach sich
  ziehen.
- Ressourcen: `w1` hat 4 GB; falls zu knapp, wird das vor Schritt 2
  entschieden (grösserer Worker oder Observability-Node).
- Bekannte Grenze: Falco sieht nicht in Kata-MicroVMs hinein (Gast-Kernel).
  Welche Befehle liefen, kommt aus den Spans des Harness; Falco dient auf dem
  Sandbox-Node als Ausbruchserkennung.

## Schritt 3: Container-Runtime (Kata)

- Neuer Node `${cluster_name_prefix}-sb1`, Variable `sandbox_machine_type`,
  Default `n2-standard-4`, `enable_nested_virtualization = true`, sonst wie
  `w1` (Shielded VM, Netz, `vm_status`). Registriert sich mit Label
  `sandbox=true` und Taint `sandbox=true:NoSchedule`.
- Kata per kata-deploy (Helm, gepinnt), nur auf `sandbox=true`. RuntimeClass
  `kata-clh` (Cloud Hypervisor) mit `scheduling.nodeSelector` + Toleration
  und Pod-Overhead.
- RuntimeClass-Patch in `kustomization.yaml` auf `kata-clh` setzen.
- **Kata erzwingen:** `ValidatingAdmissionPolicy` in `sandboxes` lehnt jeden
  Pod ohne `runtimeClassName: kata-clh` ab. Sonst liefe ein Pod ohne
  RuntimeClass still mit `runc` auf `w1`. *Meine Entscheidung.*
- Abnahme: `/dev/kvm` auf `sb1`; `uname -r` in der Sandbox ≠ Host-Kernel;
  Pod ohne RuntimeClass in `sandboxes` wird abgelehnt; Abnahmetests aus
  Schritt 1 laufen weiter; Falco-Alarme vom Sandbox-Node kommen an.
- Firecracker bleibt optional und später.

## Approaches (betrachtet)

1. **Dedizierter Sandbox-Node + Kata/Cloud Hypervisor + agent-sandbox**
   (gewählt, entspricht der Roadmap).
2. `w1` auf N2 + Nested Virt umbauen: günstiger, aber Sandboxes und normale
   Workloads teilen sich einen Node. Verworfen.
3. Firecracker statt Cloud Hypervisor: braucht devmapper-Snapshotter, mehr
   Aufwand bei kaum mehr Isolation. Später.
4. gVisor statt Kata: kein eigener Kernel, schwächere Isolation; nur für
   GPU-Sandboxes interessant, die es nicht braucht. Verworfen.

Reihenfolge: Ursprünglich Kata zuerst; der Nutzer hat entschieden, erst den
agent-sandbox-Ablauf und die Observability aufzubauen.

## Anti-Ziele

- Sandbox-Pods laufen nach Schritt 3 mit `runc` oder auf `w1`/Control Plane.
- Normale Workloads landen auf dem Sandbox-Node.
- Eine Sandbox erreicht den Metadata-Server, das Internet oder andere Pods,
  oder hat ein ServiceAccount-Token.
- Dashboards oder der Sandbox Router sind ohne Authentifizierung von aussen
  erreichbar.

## Nicht-Ziele

Warm Pools, MCP-Gateway, Orchestrator, LLM, Freigaben für Scan-Ziele
(Phase 6), statische IP der Control Plane, manipulationssichere Logs.

## Entschieden

- Pod Security für `sandboxes`: `baseline` (erlaubt Root/`NET_RAW` für
  nmap-SYN-Scans; Grenze ist ab Schritt 3 die MicroVM).
- Modell-Reihenfolge (Nutzer, 2026-11-22):
  1. Kleines Gemini-Flash-Modell zum Aufbauen der Pipeline. *Mein
     Vorschlag:* über Vertex AI in einer EU-Region im bestehenden
     GCP-Projekt (Service Account statt API-Key, Daten bleiben in der EU),
     angesprochen über die OpenAI-kompatible Schnittstelle. Achtung:
     Gemini hat eigene Guardrails, für tiefe Reviews also nur bedingt
     aussagekräftig.
  2. Lokales Modell auf einem GPU-Node (vLLM), schrittweise grösser, bis die
     Ergebnisse gut sind.
  3. Vergleich mit Frontier-Modellen per API über das LLM-Gateway.
  Für den Vergleich braucht es ein festes Testset mit bekannten
  Schwachstellen und eine Bewertung pro Modell (Funde, Fehlalarme, Tokens,
  Kosten aus den Traces). Weil schon das erste Modell pro Token kostet,
  gilt ab dem ersten Agent-Lauf: GCP-Budget-Alarm als Absicherung,
  LLM-Gateway vor dem ersten unbeaufsichtigten Lauf. Option Frontier: OpenAI Daybreak (Trusted Access for Cyber),
  angefragt; laut OpenAI auch per Responses API nutzbar
  (`access_programs.cyber`), Abrechnung dort nicht angegeben.

## Offene Entscheidungen (Nutzer)

1. ISO-27001-Metriken (Chef fragen), betrifft Schritt 2.
2. Falls Kata mit Secure Boot auf GCE nicht läuft: Secure Boot nur auf `sb1`
   abschalten oder anhalten und melden. Empfehlung: anhalten und melden.
   (Betrifft erst Schritt 3.)

## Dem Builder überlassen

Exakte Versionen (gepinnt), Label/Taint per kubelet-Flags oder Join-Config,
Basis-Image der Test-Sandbox, Pod-Overhead-Werte, Helm vs. Manifeste je
Komponente.
