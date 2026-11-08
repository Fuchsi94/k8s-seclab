# Roadmap – Security AI Agent MVP

**Ziel:** Aufbau einer portablen, selbst gehosteten Security-AI-Agent-Plattform mit Kubernetes, isolierten MicroVM-Sandboxes, MCP-Servern und einem eigenen LLM.

**MVP-Infrastruktur:** Google Compute Engine (GCE), selbst verwaltetes Kubernetes, Ubuntu 24.04 LTS.

**Ziel-Infrastruktur:** Schweizer Cloud-Anbieter mit GPU-Unterstützung und KVM-fähigen Kubernetes-Workern.

## Phase 1 – Kubernetes & Infrastruktur

- [ ] Bestehendes GCE-Kubernetes-Cluster starten
- [ ] Kubernetes-Version und Node-Status prüfen
- [ ] containerd-Version und Konfiguration prüfen
- [ ] Nested Virtualization auf GCE aktivieren
- [ ] KVM-Verfügbarkeit (`/dev/kvm`) verifizieren
- [ ] Dedizierten CPU-Worker für Sandboxes vorbereiten

**Meilenstein:** Kubernetes-Worker ist für MicroVMs vorbereitet.

## Phase 2 – Sandbox-Runtime

- [ ] Kata Containers installieren
- [ ] Cloud Hypervisor als VMM konfigurieren
- [ ] containerd-Runtime-Handler einrichten
- [ ] Kubernetes `RuntimeClass` konfigurieren
- [ ] Erste MicroVM-Sandbox starten
- [ ] Isolation, Netzwerk und Ressourcenlimits testen
- [ ] Optional: Firecracker als alternative Runtime evaluieren

**Meilenstein:** Isolierte MicroVMs laufen zuverlässig auf Kubernetes.

## Phase 3 – Kubernetes Agent Sandbox

- [ ] Agent Sandbox Controller und CRDs installieren
- [ ] Sandbox Templates konfigurieren
- [ ] Dynamische Sandbox-Erstellung implementieren
- [ ] Sandbox-Lifecycle (Create, Execute, Delete) testen
- [ ] Automatische Bereinigung und Timeouts einrichten
- [ ] Network Policies und RBAC konfigurieren

**Meilenstein:** Sandboxes können dynamisch erstellt, genutzt und gelöscht werden.

## Phase 4 – Security Tools & MCP

- [ ] MCP-Gateway einrichten
- [ ] MCP-Server für Nmap, Nuclei, Trivy und Semgrep integrieren
- [ ] Eigene Skills für Security-Scanning-Workflows entwickeln
- [ ] Tool-Ausführung innerhalb isolierter Sandboxes implementieren
- [ ] Scan-Scope-Validierung und Freigaben einrichten
- [ ] Strukturierte Findings und Reports erzeugen

**Meilenstein:** Security-Scans können kontrolliert und isoliert ausgeführt werden.

## Phase 5 – LLM & Agent-Orchestrierung

- [ ] Agent-Orchestrator implementieren
- [ ] Externe LLM-API für erste Tests anbinden
- [ ] Tool Calling und MCP-Integration testen
- [ ] NVIDIA-GPU-Worker zu Kubernetes hinzufügen
- [ ] NVIDIA-Treiber und Device Plugin konfigurieren
- [ ] DeepSeek Abliterated mit vLLM deployen
- [ ] Agent-Orchestrator auf selbst gehostetes LLM umstellen

**Meilenstein:** Der AI-Agent kann Security-Workflows über eigene Skills und MCP-Tools ausführen.

## Phase 6 – Security, Observability & Betrieb

- [ ] Kubernetes RBAC und Pod Security konfigurieren
- [ ] Netzwerkzugriffe standardmässig blockieren
- [ ] Freigegebene Scan-Ziele und Egress-Regeln erzwingen
- [ ] Secrets Management implementieren
- [ ] Audit-Logging für Agent- und Tool-Aktionen einrichten
- [ ] Prometheus und Grafana integrieren
- [ ] Sandbox-Isolation und Cleanup unter Last testen
- [ ] Kosten und Ressourcenverbrauch messen

**Meilenstein:** Die Plattform ist abgesichert, beobachtbar und stabil.

## Phase 7 – Schweizer Hosting & Migration

- [ ] Schweizer Kubernetes-/GPU-Anbieter vergleichen
- [ ] KVM, Nested Virtualization und Custom Runtimes prüfen
- [ ] GPU-Verfügbarkeit und Hosting-Kosten vergleichen
- [ ] Infrastruktur mit Terraform und Helm portabel halten
- [ ] Testdeployment beim ausgewählten Anbieter durchführen
- [ ] Datenhaltung, Logging und Backups in der Schweiz validieren
- [ ] Workloads auf Schweizer Infrastruktur migrieren

**Meilenstein:** Die Plattform läuft auf Schweizer Infrastruktur.

---

## Zielarchitektur

```text
Security Agent / API
        |
Agent Orchestrator
        |
   MCP Gateway
        |
Agent Sandbox Controller
        |
Kubernetes Cluster
   |
   +-- CPU Worker Nodes
   |     Ubuntu 24.04
   |     Kata Containers
   |     Cloud Hypervisor
   |     Isolierte Security Tools
   |
   +-- GPU Worker Nodes
         NVIDIA GPU
         vLLM
         DeepSeek Abliterated
```

## MVP-Erfolgskriterien

- [ ] Sandbox wird automatisch erstellt und gelöscht
- [ ] Security-Tools laufen isoliert in MicroVMs
- [ ] Nicht autorisierte Netzwerkzugriffe werden blockiert
- [ ] Agent kann MCP-Tools kontrolliert aufrufen
- [ ] Security-Scan liefert strukturierte Findings
- [ ] LLM kann später ohne Architekturwechsel ausgetauscht werden
- [ ] Deployment ist auf einen Schweizer Anbieter übertragbar

## Nächster Schritt

**Phase 1 starten:**

1. GCE-VM `k8s-lab-w1` starten.
2. Kubernetes und containerd prüfen.
3. KVM-Unterstützung verifizieren.
4. Dedizierten Sandbox-Worker vorbereiten.

**Priorität:** Zuerst die Sandbox-Infrastruktur stabilisieren, danach MCP und LLM integrieren.