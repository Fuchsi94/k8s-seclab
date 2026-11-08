terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
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
# SSH from the user's IP (or 0.0.0.0/0 if they haven't set it).
resource "google_compute_firewall" "ssh" {
  name          = "${var.cluster_name_prefix}-ssh"
  network       = "default"
  source_ranges = [var.your_ip]
  target_tags   = ["cks-kubeadm"]

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
  target_tags   = ["cks-kubeadm-cp"]

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }
}

# Internal cluster traffic between control plane <-> worker.
# Calico VXLAN (4789/udp), kubelet (10250), NodePort (30000-32767),
# etcd (2379-2380), control plane components.
resource "google_compute_firewall" "internal" {
  name        = "${var.cluster_name_prefix}-internal"
  network     = "default"
  source_tags = ["cks-kubeadm"]
  target_tags = ["cks-kubeadm"]

  allow {
    protocol = "tcp"
    ports    = ["2379-2380", "10250-10259", "30000-32767", "179", "5473"]
  }
  allow {
    protocol = "udp"
    ports    = ["4789", "8472"]
  }
  allow {
    protocol = "ipip"
  }
  allow {
    protocol = "icmp"
  }
}

#############################
# Locals
#############################
locals {
  startup_script = templatefile("${path.module}/scripts/install-common.sh", {
    K8S_VERSION = var.k8s_version
  })
}

#############################
# Control plane VM
#############################
resource "google_compute_instance" "control_plane" {
  name         = "${var.cluster_name_prefix}-cp"
  machine_type = var.control_plane_machine_type
  zone         = var.zone
  tags         = ["cks-kubeadm", "cks-kubeadm-cp"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 30
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    ssh-keys        = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
    startup-script  = local.startup_script
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
  tags         = ["cks-kubeadm"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 30
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    ssh-keys        = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
    startup-script  = local.startup_script
  }

  depends_on = [google_project_service.compute]
}
