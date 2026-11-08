# kubeadm Lab (CKS)

A 2-node cluster (1 control plane + 1 worker) built with kubeadm on Ubuntu
22.04 GCE VMs. Use this for the master-node-specific CKS topics that GKE
can't simulate: apiserver flags, etcd encryption-at-rest, audit policy,
kubeadm upgrades, static pod manifest editing, `/etc/kubernetes/` exploration.

For everything else (NetworkPolicy, RBAC, Falco, OPA, etc.) just use
`../gke-lab/` — it's faster to start and free-ish.

## First time

1. Find your public IP and edit `terraform.tfvars`:
   ```bash
   curl ifconfig.me
   # Set your_ip = "X.X.X.X/32" so SSH + API aren't open to the internet.
   ```

2. Apply:
   ```bash
   cd ~/Code/learning/certifications/cks/kubeadm-lab
   terraform init
   terraform apply
   ```

3. Wait ~3–4 min for the startup script to install kubeadm. Check readiness:
   ```bash
   ssh $(terraform output -raw control_plane_ip) "ls /var/lib/cks-kubeadm-ready"
   ```
   The file exists when packages are installed.

## Bootstrap the cluster (manual, exam-style)

SSH into the **control plane**:
```bash
ssh $(terraform output -raw control_plane_ip)
```

Initialize:
```bash
# Use the internal IP terraform output for --apiserver-advertise-address
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address=$(hostname -I | awk '{print $1}')

# Save the `kubeadm join` command it prints — you'll need it for the worker.

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Install Calico CNI (needed for NetworkPolicy):
```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml
```

SSH into the **worker** and run the `kubeadm join` command from above:
```bash
ssh $(terraform output -raw worker_ip)
sudo kubeadm join <cp-internal-ip>:6443 --token ... --discovery-token-ca-cert-hash sha256:...
```

Back on control plane:
```bash
kubectl get nodes   # both Ready when CNI is up
```

## Get kubeconfig on your laptop

```bash
mkdir -p ~/.kube
scp $(terraform output -raw control_plane_ip):.kube/config ~/.kube/cks-kubeadm-config
# Edit the file: replace 10.x.x.x server IP with the public control plane IP
# Then: export KUBECONFIG=~/.kube/cks-kubeadm-config
```

## Daily use

`terraform destroy` when done, `terraform apply` next session. The startup
script reinstalls packages on each boot but is idempotent (~30s if cached).
You'll re-run `kubeadm init` each time, which is **good practice** for the
exam.

## Cost

- 1× e2-medium + 1× e2-small running 8h/day: ~$0.50/day, ~$10/month.
- Destroyed nights/weekends: practically free.

## Notes

- If you bump `k8s_version` (e.g. `v1.32`), the **next** terraform apply
  recreates VMs with the new version. Practice kubeadm upgrades on a single
  apply by SSH-ing in and following the official upgrade docs instead.
- The `your_ip` var is your home/work IP. If it changes (mobile, café), re-run
  `curl ifconfig.me`, update tfvars, `terraform apply` — only the firewall
  rules change, VMs aren't touched.
