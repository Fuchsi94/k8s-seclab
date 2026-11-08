output "control_plane_ip" {
  value = google_compute_instance.control_plane.network_interface[0].access_config[0].nat_ip
}

output "worker_ip" {
  value = google_compute_instance.worker.network_interface[0].access_config[0].nat_ip
}

output "control_plane_internal_ip" {
  value = google_compute_instance.control_plane.network_interface[0].network_ip
}

output "ssh_control_plane" {
  value = "ssh ${var.ssh_user}@${google_compute_instance.control_plane.network_interface[0].access_config[0].nat_ip}"
}

output "ssh_worker" {
  value = "ssh ${var.ssh_user}@${google_compute_instance.worker.network_interface[0].access_config[0].nat_ip}"
}
