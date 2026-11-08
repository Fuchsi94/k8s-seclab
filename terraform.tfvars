project_id = "codify-playground-yannick"
region     = "europe-west3"
zone       = "europe-west3-a"

ssh_user            = "yannick"
ssh_public_key_path = "keys/lab.pub"

# Find with: curl -s ifconfig.me
# Update this every time your IP changes. Use 0.0.0.0/0 only as a last resort.
your_ip = "193.5.234.182/32"

k8s_version = "v1.36"

cluster_name_prefix        = "k8s-lab"
control_plane_machine_type = "e2-medium"
worker_machine_type        = "e2-medium"
vm_status                  = null # Preserve the existing stopped status.
