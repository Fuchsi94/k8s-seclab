terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

#############################
# Network
#############################
# Dedicated VPC: only the firewall rules below apply. The default VPC has
# pre-existing rules that open SSH/RDP to the whole internet.
resource "google_compute_network" "lab" {
  name                    = "${var.cluster_name_prefix}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "lab" {
  name                     = "${var.cluster_name_prefix}-subnet"
  region                   = var.region
  network                  = google_compute_network.lab.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

#############################
# Firewall rules
#############################
# SSH from your IP only.
resource "google_compute_firewall" "ssh" {
  name          = "${var.cluster_name_prefix}-ssh"
  network       = google_compute_network.lab.id
  source_ranges = [var.your_ip]
  target_tags   = [var.cluster_name_prefix]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  lifecycle {
    replace_triggered_by = [google_compute_network.lab.id]
  }
}

# Kubernetes API server (6443), control plane only, from your IP only.
resource "google_compute_firewall" "k8s_api" {
  name          = "${var.cluster_name_prefix}-api"
  network       = google_compute_network.lab.id
  source_ranges = [var.your_ip]
  target_tags   = ["${var.cluster_name_prefix}-cp"]

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }

  lifecycle {
    replace_triggered_by = [google_compute_network.lab.id]
  }
}

# Everything between the nodes (API server, kubelet, etcd, Cilium VXLAN,
# health checks, Hubble, ...). The subnet only contains lab nodes.
resource "google_compute_firewall" "internal" {
  name          = "${var.cluster_name_prefix}-internal"
  network       = google_compute_network.lab.id
  source_ranges = [google_compute_subnetwork.lab.ip_cidr_range, var.pod_cidr]
  target_tags   = [var.cluster_name_prefix]

  allow {
    protocol = "all"
  }

  lifecycle {
    replace_triggered_by = [google_compute_network.lab.id]
  }
}

#############################
# Bootstrap token + startup scripts
#############################
# kubeadm bootstrap token, format [a-z0-9]{6}.[a-z0-9]{16}. The control plane
# creates it during `kubeadm init`, the worker uses it for `kubeadm join`.
resource "random_password" "token_id" {
  length  = 6
  special = false
  upper   = false
}

resource "random_password" "token_secret" {
  length  = 16
  special = false
  upper   = false
}

locals {
  join_token = "${random_password.token_id.result}.${random_password.token_secret.result}"

  startup_script_vars = {
    K8S_VERSION        = var.k8s_version
    CILIUM_VERSION     = var.cilium_version
    CILIUM_CLI_VERSION = var.cilium_cli_version
    JOIN_TOKEN         = local.join_token
    SSH_USER           = var.ssh_user
    POD_CIDR           = var.pod_cidr
  }

  common_metadata = {
    # Only the key below may log in; project-wide keys (e.g. added by
    # `gcloud compute ssh`) are ignored.
    block-project-ssh-keys = "true"
    enable-oslogin         = "FALSE"
    ssh-keys               = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
  }
}

#############################
# Control plane VM
#############################
resource "google_compute_instance" "control_plane" {
  name           = "${var.cluster_name_prefix}-cp"
  machine_type   = var.control_plane_machine_type
  zone           = var.zone
  can_ip_forward = true
  desired_status = var.vm_status
  tags           = [var.cluster_name_prefix, "${var.cluster_name_prefix}-cp"]

  boot_disk {
    initialize_params {
      image = var.image
      size  = 30
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.lab.id
    access_config {}
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = merge(local.common_metadata, {
    startup-script = templatefile("${path.module}/scripts/install-common.sh", merge(local.startup_script_vars, {
      ROLE           = "controlplane"
      CP_INTERNAL_IP = ""
    }))
  })

  # The cluster is bound to the node IPs (certs, kubelet config). A new
  # subnet means new IPs, so rebuild the VMs and let the bootstrap run again.
  lifecycle {
    replace_triggered_by = [google_compute_subnetwork.lab.id]
  }
}

#############################
# Worker VM
#############################
resource "google_compute_instance" "worker" {
  name           = "${var.cluster_name_prefix}-w1"
  machine_type   = var.worker_machine_type
  zone           = var.zone
  can_ip_forward = true
  desired_status = var.vm_status
  tags           = [var.cluster_name_prefix]

  boot_disk {
    initialize_params {
      image = var.image
      size  = 30
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.lab.id
    access_config {}
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = merge(local.common_metadata, {
    startup-script = templatefile("${path.module}/scripts/install-common.sh", merge(local.startup_script_vars, {
      ROLE           = "worker"
      CP_INTERNAL_IP = google_compute_instance.control_plane.network_interface[0].network_ip
    }))
  })

  # The cluster is bound to the node IPs (certs, kubelet config). A new
  # subnet means new IPs, so rebuild the VMs and let the bootstrap run again.
  lifecycle {
    replace_triggered_by = [google_compute_subnetwork.lab.id]
  }
}
