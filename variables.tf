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
  description = "Your IP in CIDR form (e.g. 1.2.3.4/32) — opens K8s API port 6443 only to you. Get from: curl ifconfig.me"
}

variable "k8s_version" {
  type        = string
  description = "Kubernetes minor version family for the apt repo (e.g. v1.31). CKS exam currently runs ~1.31."
  default     = "v1.31"
}

variable "control_plane_machine_type" {
  type        = string
  description = "Control plane node size. kubeadm requires >=2 vCPU + >=2 GB."
  default     = "e2-medium"
}

variable "worker_machine_type" {
  type        = string
  description = "Worker node size"
  default     = "e2-small"
}

variable "cluster_name_prefix" {
  type        = string
  default     = "cks-kubeadm"
}
