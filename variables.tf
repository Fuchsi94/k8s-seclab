variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region"
}

variable "zone" {
  type        = string
  description = "GCP zone"
}

variable "ssh_user" {
  type        = string
  description = "SSH username on the VMs"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to your SSH public key"
}

variable "your_ip" {
  type        = string
  description = "Your IP in CIDR form (e.g. 1.2.3.4/32) — opens K8s API port 6443 only to you. Get from: curl -4 ifconfig.me"
}

variable "k8s_version" {
  type        = string
  description = "Kubernetes minor version for the pkgs.k8s.io apt repo (e.g. v1.36). kubeadm deploys the latest patch of this minor. Keep it within the Cilium tested range."
  default     = "v1.36"
}

variable "control_plane_machine_type" {
  type        = string
  description = "Control plane node size. kubeadm requires >=2 vCPU + >=2 GB."
  default     = "e2-medium"
}

variable "worker_machine_type" {
  type        = string
  description = "Worker node size. e2-small (2 GB) is too tight for Cilium + workloads."
  default     = "e2-medium"
}

variable "cluster_name_prefix" {
  type    = string
  default = "gcp-sec-lab"
}

variable "cilium_version" {
  type        = string
  description = "Cilium version (without v). Check k8s compatibility: docs.cilium.io/en/stable/network/kubernetes/compatibility/. 1.20 is tested up to k8s 1.36."
  default     = "1.20.4"
}

variable "cilium_cli_version" {
  type        = string
  description = "cilium-cli release tag used to install Cilium."
  default     = "v0.20.2"
}

variable "image" {
  type        = string
  description = "Boot image for all nodes."
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR of the lab subnet (node IPs)."
  default     = "10.30.0.0/24"
}

variable "pod_cidr" {
  type        = string
  description = "Pod network CIDR (kubeadm --pod-network-cidr). Must not overlap subnet_cidr."
  default     = "192.168.0.0/16"
}

variable "vm_status" {
  type        = string
  description = "Desired VM status: RUNNING, TERMINATED (stopped), or null to leave it as it is."
  default     = null

  validation {
    condition     = var.vm_status == null ? true : contains(["RUNNING", "TERMINATED"], var.vm_status)
    error_message = "vm_status must be RUNNING or TERMINATED."
  }
}
