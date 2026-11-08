# kubeadm Lab (CKS)

A 2-node cluster (1 control plane + 1 worker) built with kubeadm on Ubuntu
24.04 GCE VMs. Use this for the master-node-specific CKS topics that GKE
can't simulate: apiserver flags, etcd encryption-at-rest, audit policy,
kubeadm upgrades, static pod manifest editing, `/etc/kubernetes/` exploration.

For everything else (NetworkPolicy, RBAC, Falco, OPA, etc.) just use
`../gke-lab/` — it's faster to start and free-ish.

## Existing lab and state

This checkout manages the existing resources in project
`codify-playground-yannick`, zone `europe-west3-a`:

- `google_compute_instance.control_plane`: `k8s-lab-cp`, e2-medium, 10.30.0.2
- `google_compute_instance.worker`: `k8s-lab-w1`, e2-medium, 10.30.0.3
- `google_compute_network.lab`: `k8s-lab-vpc`
- `google_compute_subnetwork.lab`: `k8s-lab-subnet`, 10.30.0.0/24
- `google_compute_firewall.ssh`: `k8s-lab-ssh`
- `google_compute_firewall.internal`: `k8s-lab-internal`
- `google_project_service.compute`: Compute Engine API

The migration imports resources without applying cloud changes.

Terraform uses local state. Back up `terraform.tfstate` securely before moving
or deleting this checkout. State and backup files are ignored by Git. Cloning
this repository does not restore resource ownership: recover the state or
import the existing resources before applying from another checkout.

The VMs remain stopped (`vm_status = null` preserves their current status). Their existing startup
script, SSH public key (`keys/lab.pub`), Secure Boot configuration, internal
IPs and network are preserved. SSH requires the private key matching this
public key; your local default key may be different. The boot image is pinned
to the existing image to avoid migration drift.

```bash
terraform init
terraform plan
```

SSH is restricted to the existing allowed IP in `terraform.tfvars`; update it
if needed and inspect the plan. There is no public Kubernetes API firewall
rule. Use SSH to administer the cluster on the control plane.

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

## Daily use

To start both VMs, set `vm_status = "RUNNING"` in `terraform.tfvars`, then run
`terraform plan` and `terraform apply`. To stop them, set it back to
`"TERMINATED"` and apply. Stopped VMs retain their disks and cluster data;
disks continue to incur charges. Ephemeral public IPs may change on restart.

Use `terraform output ssh_control_plane` and `terraform output ssh_worker`
for SSH commands once the VMs are running. The startup readiness marker is
`/var/lib/k8s-lab-ready`. Check existing cluster status before running the
manual bootstrap commands above; bootstrap is only needed for a fresh cluster.

`terraform destroy` deletes the managed VMs, boot disks, firewall rules,
subnet and network. It is not the daily stop command.

## Notes

Changing `k8s_version` updates startup-script metadata. The script exits if
`/var/lib/k8s-lab-ready` exists, so this does not upgrade an existing cluster.
Perform kubeadm upgrades explicitly on the nodes.
