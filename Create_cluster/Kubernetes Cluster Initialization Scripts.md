# Kubernetes Cluster Initialization Scripts

These scripts are created to initialize a Kubernetes cluster using kubeadm after you have already installed all the required components using a script.
setup_node.sh`.

**⚠️ IMPORTANT: Open and read the script first! All usage examples and parameters are documented inside the script comments.**

## Prerequisites

Before using these scripts, make sure that the `setup_node.sh` script has been executed on all nodes (master and worker), which installs:

- runc
- containerd
- kubelet
- kubeadm
- kubectl
- etcd (for master)
- crictl

And also configures:

- Kernel modules (overlay, br_netfilter)
- Sysctl parameters (IP forwarding, bridge netfilter)
- Hostname with FQDN

## Scripts

### 1. `init_master.sh` — init Master-node

This script initializes the Kubernetes cluster control plane.

#### Use

```bash
# Use base (Flannel CNI, pod network 10.244.0.0/16)
sudo ./init_master.sh

# With pod network CIDR specified
sudo ./init_master.sh 10.244.0.0/16

# With CNI plugin specified(flannel, calico, cilium)
sudo ./init_master.sh 10.244.0.0/16 flannel
sudo ./init_master.sh 192.168.0.0/16 calico
sudo ./init_master.sh 10.0.0.0/16 cilium
```

#### What does the script do

1. **Pre-flight check** — checks the presence of all necessary components
2. **Setting containerd** — creates a configuration and systemd service
3. **Setting kubelet** — creates a systemd service and drop-in configuration
4. **init кластера** — run `kubeadm init`
5. **Setting kubectl** — copies kubeconfig for root and sudo user
6. **Setup CNI** — installs the selected CNI plugin (Flannel, Calico or Cilium)
7. **Save join commands** - saves commands for connecting worker and control plane nodes

#### Result

After successful execution of the script:

- The cluster is initialized and ready to use
- kubectl is configured and ready to use
- The CNI plugin is installed
- Join commands are saved in:
- `/tmp/worker-join-command.sh` — for connecting worker nodes
- `/tmp/control-plane-join-command.sh` — for adding additional master nodes

#### Check

```bash
# Check node status
kubectl get nodes

# Check system pods
kubectl get pods -n kube-system

# Check cluster information
kubectl cluster-info
```

---

### 2. `join_worker.sh` — Connecting a Worker Node (Advanced)

A fully functional script for connecting a worker node with checks and diagnostics.

#### Use

```bash
# Option 1: Specify parameters separately
sudo ./join_worker.sh <master-ip> <token> <ca-cert-hash>

# Example
sudo ./join_worker.sh 192.168.1.100 abcdef.0123456789abcdef sha256:1234567890abcdef...

# Option 2: Pass the full join command
sudo ./join_worker.sh "kubeadm join 192.168.1.100:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxx"
```

#### What the script does

1. **Pre-flight checks** — checks components, modules, sysctl
2. **Connectivity check** — checks the availability of the master node and server API
3. **Configure containerd** — creates the configuration and systemd service
4. **Configure kubelet** — creates the systemd service
5. **Cleanup** — removes the old configuration (if any)
6. **Connection** — executes `kubeadm join`
7. **Verification** — checks the kubelet status

---

### 3. `join_worker_simple.sh` — Connecting a Worker Node (Simplified)

A simplified version for quickly connecting a worker node.

#### Use

```bash
# Option 1: Copy the join command from the master node
# In master:
cat /tmp/worker-join-command.sh

# Copy the file to the worker node in /tmp/worker-join-command.sh
# In worker:
sudo ./join_worker_simple.sh

# Option 2: Pass the join command as an argument
sudo ./join_worker_simple.sh "kubeadm join 192.168.1.100:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxx"
```

#### What the script does

1. Configures containerd
2. Configures kubelet
3. Clears the old configuration
4. Runs `kubeadm join`

---

## Step-by-step instructions for deploying a cluster

### Step 1: Preparing all nodes

On all nodes (master and worker), run:

```bash
sudo ./setup_node.sh <hostname>
```

Example:
```bash
# In master nodes
sudo ./setup_node.sh master-1

# In worker nodes
sudo ./setup_node.sh worker-1
sudo ./setup_node.sh worker-2
sudo ./setup_node.sh worker-3
```
### Step 2: Initialize the master node

On the master node:

```bash
sudo ./init_master.sh
```

Or with the CNI specified:

```bash
sudo ./init_master.sh 10.244.0.0/16 calico
```

### Step 3: Save the join command

On the master node after initialization:

```bash
# View the join command for worker nodes
cat /tmp/worker-join-command.sh

# Copy the command to the clipboard or save it to a file
```

### Step 4: Connecting Worker Nodes

On each worker node, run one of the following:

**Option A: Simplified script with a command**

```bash
sudo ./join_worker_simple.sh "kubeadm join 192.168.1.100:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:1234567890abcdef..."
```

**Option B: Simplified script with a file**

```bash
# Copy /tmp/worker-join-command.sh from master to worker
scp root@master-1:/tmp/worker-join-command.sh /tmp/

# Execute the script
sudo ./join_worker_simple.sh
```

**Option C: Advanced Script**

```bash
sudo ./join_worker.sh 192.168.1.100 abcdef.0123456789abcdef sha256:1234567890abcdef...
```

### Step 5: Check the cluster

On the master node:

```bash
# Check all nodes
kubectl get nodes

# Output should look like this:
# NAME STATUS ROLES AGE VERSION
# master-1.test-cluster.test.com Ready control-plane 5m v1.30.4
# worker-1.test-cluster.test.com Ready <none> 2m v1.30.4
# worker-2.test-cluster.test.com Ready <none> 1m v1.30.4

# Check pods
kubectl get pods -A

# Deploy the test application
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get svc nginx
```

---

## Supported CNI Plugins

### Flannel (default)

```bash
sudo ./init_master.sh 10.244.0.0/16 flannel
```

- Simple and reliable
- Recommended for most use cases
- Pod network CIDR: `10.244.0.0/16`

### Calico

```bash
sudo ./init_master.sh 192.168.0.0/16 calico
```

- Advanced network policies
- Better performance
- Pod network CIDR: `192.168.0.0/16`

### Cilium

```bash
sudo ./init_master.sh 10.0.0.0/16 cilium
```

- eBPF-based Networking
- Advanced Security
- Pod Network CIDR: `10.0.0.0/16`

---

## Troubleshooting

### Problem: Node doesn't appear in the cluster

```bash
# Check kubelet logs on the worker node
sudo journalctl -u kubelet -f

# Check kubelet status
sudo systemctl status kubelet
```

### Problem: Node is in NotReady status

```bash
# Check CNI plugin
kubectl get pods -n kube-system | grep -E 'flannel|calico|cilium'

# Check CNI logs
kubectl logs -n kube-system <cni-pod-name>
```

### Problem: Token expired

Create a new token on the master node:

```bash
# Create a new token
kubeadm token create --print-join-command

# This will print the full join command, which can be used on worker nodes.
```

### Problem: The node needs to be reinitialized

```bash
# Reset the node
sudo kubeadm reset -f

# Clear the configuration
sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd

# Then re-run init or join
```

---

## Additional commands

### Adding additional master nodes (HA setup)

On the master node after initialization:

```bash
# View the command to add a control plane node
cat /tmp/control-plane-join-command.sh

# Run this command on the new master node
```

### Removing a node from the cluster

```bash
# On the master node
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node-name>

# On the node being removed
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/kubelet
```

### Getting kubeconfig for remote access

```bash
# On the master node
cat /etc/kubernetes/admin.conf

# Copy the contents to the local machine in ~/.kube/config
# Change the server URL to the master node's external IP
```

---

## Cluster Architecture

After deployment, you will have:

```
┌─────────────────────────────────────────────────────────────┐
│                     Master Node                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Control Plane Components                            │   │
│  │  - kube-apiserver                                    │   │
│  │  - kube-controller-manager                           │   │
│  │  - kube-scheduler                                    │   │
│  │  - etcd                                              │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Node Components                                     │   │
│  │  - kubelet                                           │   │
│  │  - containerd                                        │   │
│  │  - CNI plugin                                        │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ API Server (6443)
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
┌───────▼────────┐  ┌───────▼────────┐  ┌───────▼────────┐
│  Worker Node 1 │  │  Worker Node 2 │  │  Worker Node 3 │
│  ┌──────────┐  │  │  ┌──────────┐  │  │  ┌──────────┐  │
│  │ kubelet  │  │  │  │ kubelet  │  │  │  │ kubelet  │  │
│  │containerd│  │  │  │containerd│  │  │  │containerd│  │
│  │   CNI    │  │  │  │   CNI    │  │  │  │   CNI    │  │
│  └──────────┘  │  │  └──────────┘  │  │  └──────────┘  │
│  ┌──────────┐  │  │  ┌──────────┐  │  │  ┌──────────┐  │
│  │   Pods   │  │  │  │   Pods   │  │  │  │   Pods   │  │
│  └──────────┘  │  │  └──────────┘  │  │  └──────────┘  │
└────────────────┘  └────────────────┘  └────────────────┘
```

---

## Component Versions

These scripts are configured to work with the versions installed by `setup_node.sh`:

- **Kubernetes**: v1.30.4
- **containerd**: 1.7.19
- **runc**: v1.1.12
- **etcd**: v3.5.12
- **crictl**: v1.30.0

---

## License and Support

These scripts are an addition to your `setup_node.sh` script and are designed to automate the deployment of a production-ready Kubernetes cluster.

For more information, please refer to the official documentation:
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [kubeadm Documentation](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)
