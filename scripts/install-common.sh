#!/usr/bin/env bash
# Installs containerd + kubeadm/kubelet/kubectl on Ubuntu 22.04.
# Runs as root via GCP startup script. Idempotent on reboot.
#
# Templated by Terraform: ${K8S_VERSION} is substituted at apply time.
set -euo pipefail

# Bail early if already installed (rerun on reboot).
if command -v kubeadm >/dev/null 2>&1; then
  exit 0
fi

# --- 1. Kernel prerequisites ---
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# --- 2. containerd ---
apt-get update
apt-get install -y containerd apt-transport-https ca-certificates curl gpg

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# --- 3. kubeadm/kubelet/kubectl (from pkgs.k8s.io) ---
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /
EOF

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

# Mark provisioning done so the user knows when to log in.
touch /var/lib/cks-kubeadm-ready
