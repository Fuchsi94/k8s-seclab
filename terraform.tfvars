project_id = "codify-playground-yannick"
region     = "europe-west3"
zone       = "europe-west3-a"

ssh_user            = "yannick"
ssh_public_key_path = "keys/lab.pub"

# Public IPv4s allowed to reach SSH + API. Find with: echo "$(curl -4 -s ifconfig.me)/32"
# Never use 0.0.0.0/0.
allowed_ips = [
  "193.5.234.182/32", # home
  "85.7.26.122/32",   # office
]

k8s_version = "v1.36"

# null = leave VMs as they are, "RUNNING" = start, "TERMINATED" = stop
vm_status = null
