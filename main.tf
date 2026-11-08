terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  # Preserve existing labels during adoption.
  add_terraform_attribution_label = false
  project                         = var.project_id
  region                          = var.region
  zone                            = var.zone
}

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_network" "lab" {
  name                    = "${var.cluster_name_prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "lab" {
  name                     = "${var.cluster_name_prefix}-subnet"
  region                   = var.region
  network                  = google_compute_network.lab.id
  ip_cidr_range            = "10.30.0.0/24"
  private_ip_google_access = true
}

resource "google_compute_firewall" "ssh" {
  name          = "${var.cluster_name_prefix}-ssh"
  network       = google_compute_network.lab.id
  source_ranges = [var.your_ip]
  target_tags   = [var.cluster_name_prefix]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "internal" {
  name          = "${var.cluster_name_prefix}-internal"
  network       = google_compute_network.lab.id
  source_ranges = ["192.168.0.0/16", google_compute_subnetwork.lab.ip_cidr_range]
  target_tags   = [var.cluster_name_prefix]

  allow {
    protocol = "all"
  }
}

locals {
  startup_script = templatefile("${path.module}/scripts/install-common.sh", {
    K8S_VERSION = var.k8s_version
  })
}

resource "google_compute_instance" "control_plane" {
  name           = "${var.cluster_name_prefix}-cp"
  machine_type   = var.control_plane_machine_type
  zone           = var.zone
  can_ip_forward = true
  desired_status = var.vm_status
  tags           = [var.cluster_name_prefix, "${var.cluster_name_prefix}-cp"]

  boot_disk {
    device_name = "persistent-disk-0"
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-noble-amd64-v20261021"
      size  = 30
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.lab.id
    network_ip = "10.30.0.2"
    access_config {}
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    block-project-ssh-keys = "true"
    enable-oslogin         = "FALSE"
    ssh-keys               = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
    startup-script         = local.startup_script
  }

  depends_on = [google_project_service.compute]
}

resource "google_compute_instance" "worker" {
  name           = "${var.cluster_name_prefix}-w1"
  machine_type   = var.worker_machine_type
  zone           = var.zone
  can_ip_forward = true
  desired_status = var.vm_status
  tags           = [var.cluster_name_prefix]

  boot_disk {
    device_name = "persistent-disk-0"
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-noble-amd64-v20261021"
      size  = 30
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.lab.id
    network_ip = "10.30.0.3"
    access_config {}
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    block-project-ssh-keys = "true"
    enable-oslogin         = "FALSE"
    ssh-keys               = "${var.ssh_user}:${file(var.ssh_public_key_path)}"
    startup-script         = local.startup_script
  }

  depends_on = [google_project_service.compute]
}
