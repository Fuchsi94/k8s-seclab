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
  description = "Kubernetes minor version family used by the startup script."
  default     = "v1.36"
}

variable "control_plane_machine_type" {
  type        = string
  description = "Control plane node size. kubeadm requires >=2 vCPU + >=2 GB."
  default     = "e2-medium"
}

variable "worker_machine_type" {
  type        = string
  description = "Worker node size"
  default     = "e2-medium"
}

variable "cluster_name_prefix" {
  type    = string
  default = "k8s-lab"
}

variable "vm_status" {
  type        = string
  description = "Desired VM status, or null to preserve the current status."
  default     = null

  validation {
    condition     = var.vm_status == null ? true : contains(["RUNNING", "TERMINATED"], var.vm_status)
    error_message = "vm_status must be RUNNING or TERMINATED."
  }
}
