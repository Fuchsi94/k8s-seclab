project_id = "codify-playground-yannick"
region     = "europe-west3"
zone       = "europe-west3-a"

ssh_user            = "yannick"
ssh_public_key_path = "~/.ssh/id_ed25519.pub"

# Find with: curl -s ifconfig.me
# Update this every time your IP changes. Use 0.0.0.0/0 only as a last resort.
your_ip = "0.0.0.0/0"

k8s_version = "v1.31"
