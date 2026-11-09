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
# Firewall rules
#############################
# SSH from your IP. Note: the default VPC also has default-allow-ssh (0.0.0.0/0).
resource "google_compute_firewall" "ssh" {
  name          = "${var.cluster_name_prefix}-ssh"
  network       = "default"
  source_ranges = [var.your_ip]
  target_tags   = [var.cluster_name_prefix]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Kubernetes API server (6443) — only from your IP.
resource "google_compute_firewall" "k8s_api" {
  name          = "${var.cluster_name_prefix}-api"
  network       = "default"
  source_ranges = [var.your_ip]
  target_tags   = ["${var.cluster_name_prefix}-cp"]

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }
}

# Internal cluster traffic between control plane <-> worker.
# API server (6443), etcd (2379-2380), kubelet + control plane components
# (10250-10259), NodePort (30000-32767), Cilium health (4240), Hubble (4244),
# Cilium VXLAN (8472/udp).
resource "google_compute_firewall" "internal" {
  name        = "${var.cluster_name_prefix}-internal"
  network     = "default"
  source_tags = [var.cluster_name_prefix]
  target_tags = [var.cluster_name_prefix]

  allow {
    protocol = "tcp"
    ports    = ["6443", "2379-2380", "10250-10259", "30000-32767", "4240", "4244"]
  }
  allow {
    protocol = "udp"
    ports    = ["8472"]
  }
  allow {
    protocol = "icmp"
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
  }
}

#############################
# Control plane VM
#############################
resource "google_compute_instance" "control_plane" {
  name         = "${var.cluster_name_prefix}-cp"
  machine_type = var.control_plane_machine_type
  zone         = var.zone
  tags         = [var.cluster_name_prefix, "${var.cluster_name_prefix}-cp"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 30
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
    startup-script = templatefile("${path.module}/scripts/install-common.sh", merge(local.startup_script_vars, {
      ROLE           = "controlplane"
      CP_INTERNAL_IP = ""
    }))
  }

  depends_on = [google_project_service.compute]
}

#############################
# Worker VM
#############################
resource "google_compute_instance" "worker" {
  name         = "${var.cluster_name_prefix}-w1"
  machine_type = var.worker_machine_type
  zone         = var.zone
  tags         = [var.cluster_name_prefix]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 30
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
    startup-script = templatefile("${path.module}/scripts/install-common.sh", merge(local.startup_script_vars, {
      ROLE           = "worker"
      CP_INTERNAL_IP = google_compute_instance.control_plane.network_interface[0].network_ip
    }))
  }

  depends_on = [google_project_service.compute]
}
