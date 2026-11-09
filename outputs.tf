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

output "fetch_kubeconfig" {
  description = "Copies the admin kubeconfig to your laptop and points it at the public control plane IP."
  value       = "mkdir -p ~/.kube && scp ${var.ssh_user}@${google_compute_instance.control_plane.network_interface[0].access_config[0].nat_ip}:.kube/config ~/.kube/${var.cluster_name_prefix} && chmod 600 ~/.kube/${var.cluster_name_prefix} && kubectl --kubeconfig ~/.kube/${var.cluster_name_prefix} config set-cluster kubernetes --server=https://${google_compute_instance.control_plane.network_interface[0].access_config[0].nat_ip}:6443"
}
