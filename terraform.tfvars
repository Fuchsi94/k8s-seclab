project_id = "codify-playground-yannick"
region     = "europe-west3"
zone       = "europe-west3-a"

ssh_user            = "yannick"
ssh_public_key_path = "keys/lab.pub"

# Find with: echo "$(curl -4 -s ifconfig.me)/32"  (IPv4!)
# Update this every time your IP changes. Use 0.0.0.0/0 only as a last resort.
your_ip = "85.7.26.122/32"

k8s_version = "v1.36"

# null = leave VMs as they are, "RUNNING" = start, "TERMINATED" = stop
vm_status = null
