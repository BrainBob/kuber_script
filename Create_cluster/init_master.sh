#!/bin/bash
# Kubernetes Master Node Initialization Script
# Usage: sudo ./init_master.sh [pod-network-cidr] [cni-plugin]
# Example: sudo ./init_master.sh 10.244.0.0/16 flannel

set -e # Stop on error

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions for beautiful output
print_header() {
    echo -e "\n${GREEN}=== $1 ===${NC}"
}

print_step() {
    echo -e "${YELLOW}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
    exit 1
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Check root privileges
if [ "$EUID" -ne 0 ]; then 
    print_error "Run the script with sudo: sudo $0"
fi

# Configuration
POD_NETWORK_CIDR="${1:-10.244.0.0/16}"
CNI_PLUGIN="${2:-flannel}"
CLUSTER_NAME="test-cluster"
KUBERNETES_VERSION="v1.30.4"

print_header "Kubernetes Master Node Initialization"
echo "Pod Network CIDR: $POD_NETWORK_CIDR"
echo "CNI Plugin: $CNI_PLUGIN"
echo "Kubernetes Version: $KUBERNETES_VERSION"
echo ""

# =========================================
# 1. Pre-flight checks
# =========================================
print_header "1. Pre-flight checks"

print_step "Checking required components..."
for component in kubeadm kubelet kubectl containerd; do
    if command -v $component &> /dev/null; then
        version=$($component --version 2>/dev/null | head -n1 || echo "installed")
        print_success "$component: $version"
    else
        print_error "$component is not installed"
    fi
done

print_step "Checking kernel modules..."
for module in overlay br_netfilter; do
    if lsmod | grep -q $module; then
        print_success "$module module loaded"
    else
        print_error "$module module not loaded"
    fi
done

print_step "Checking sysctl settings..."
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; then
    print_success "IP forwarding enabled"
else
    print_error "IP forwarding not enabled"
fi

# =========================================
# 2. Configure containerd
# =========================================
print_header "2. Configuring containerd"

print_step "Creating containerd configuration directory..."
mkdir -p /etc/containerd

print_step "Generating default containerd config..."
containerd config default > /etc/containerd/config.toml

print_step "Enabling SystemdCgroup..."
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

print_step "Creating containerd systemd service..."
cat <<EOF > /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

print_step "Starting and enabling containerd..."
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd

if systemctl is-active --quiet containerd; then
    print_success "containerd is running"
else
    print_error "containerd failed to start"
fi

# =========================================
# 3. Configure kubelet
# =========================================
print_header "3. Configuring kubelet"

print_step "Creating kubelet systemd service..."
cat <<EOF > /etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

print_step "Creating kubelet service drop-in directory..."
mkdir -p /etc/systemd/system/kubelet.service.d

print_step "Creating kubeadm drop-in configuration..."
cat <<EOF > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF

print_step "Enabling kubelet..."
systemctl daemon-reload
systemctl enable kubelet

print_success "kubelet configured (will start after kubeadm init)"

# =========================================
# 4. Initialize Kubernetes cluster
# =========================================
print_header "4. Initializing Kubernetes cluster"

print_step "Running kubeadm init..."
print_info "This may take several minutes..."

kubeadm init \
    --pod-network-cidr=$POD_NETWORK_CIDR \
    --kubernetes-version=$KUBERNETES_VERSION \
    --upload-certs \
    --control-plane-endpoint="$(hostname -f):6443" \
    | tee /tmp/kubeadm-init.log

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    print_success "Kubernetes cluster initialized successfully"
else
    print_error "kubeadm init failed"
fi

# =========================================
# 5. Configure kubectl for current user
# =========================================
print_header "5. Configuring kubectl"

print_step "Setting up kubeconfig for root user..."
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

print_success "kubectl configured for root user"

# Configure for sudo user if script was run with sudo
if [ -n "$SUDO_USER" ]; then
    print_step "Setting up kubeconfig for user: $SUDO_USER..."
    SUDO_HOME=$(eval echo ~$SUDO_USER)
    mkdir -p $SUDO_HOME/.kube
    cp -f /etc/kubernetes/admin.conf $SUDO_HOME/.kube/config
    chown -R $SUDO_USER:$SUDO_USER $SUDO_HOME/.kube
    print_success "kubectl configured for user: $SUDO_USER"
fi

# =========================================
# 6. Install CNI plugin
# =========================================
print_header "6. Installing CNI plugin: $CNI_PLUGIN"

case $CNI_PLUGIN in
    flannel)
        print_step "Installing Flannel CNI..."
        kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
        print_success "Flannel CNI installed"
        ;;
    calico)
        print_step "Installing Calico CNI..."
        kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml
        kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/custom-resources.yaml
        print_success "Calico CNI installed"
        ;;
    cilium)
        print_step "Installing Cilium CNI..."
        
        # Скачивание cilium-cli
        CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
        CLI_ARCH=amd64
        curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
        sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
        sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
        rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    
        # Установка Cilium
        cilium install --version v1.15.0
        cilium status --wait
    
        print_success "Cilium CNI установлен"
        ;;
        
    *)
        print_info "Unknown CNI plugin: $CNI_PLUGIN. Skipping CNI installation."
        print_info "Please install CNI manually."
        ;;
esac

# =========================================
# 7. Extract join commands
# =========================================
print_header "7. Extracting join commands"

print_step "Saving worker join command..."
WORKER_JOIN_CMD=$(grep -A 2 "kubeadm join" /tmp/kubeadm-init.log | grep -v "control-plane" | tr '\n' ' ' | sed 's/\\//')
echo "$WORKER_JOIN_CMD" > /tmp/worker-join-command.sh
chmod +x /tmp/worker-join-command.sh
print_success "Worker join command saved to: /tmp/worker-join-command.sh"

print_step "Saving control plane join command..."
CONTROL_PLANE_JOIN=$(grep -A 3 "kubeadm join" /tmp/kubeadm-init.log | tail -n 4 | tr '\n' ' ' | sed 's/\\//')
echo "$CONTROL_PLANE_JOIN" > /tmp/control-plane-join-command.sh
chmod +x /tmp/control-plane-join-command.sh
print_success "Control plane join command saved to: /tmp/control-plane-join-command.sh"

# =========================================
# 8. Verification
# =========================================
print_header "8. Cluster verification"

print_step "Waiting for cluster to be ready..."
sleep 10

print_step "Checking cluster info..."
kubectl cluster-info

print_step "Checking node status..."
kubectl get nodes

print_step "Checking system pods..."
kubectl get pods -n kube-system

# =========================================
# Final summary
# =========================================
print_header "Installation Complete!"

echo ""
echo -e "${GREEN}Master node initialized successfully!${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. Copy the worker join command to your worker nodes:"
echo -e "   ${YELLOW}cat /tmp/worker-join-command.sh${NC}"
echo ""
echo "2. Or copy the control plane join command to add more master nodes:"
echo -e "   ${YELLOW}cat /tmp/control-plane-join-command.sh${NC}"
echo ""
echo "3. Check cluster status:"
echo -e "   ${YELLOW}kubectl get nodes${NC}"
echo -e "   ${YELLOW}kubectl get pods -A${NC}"
echo ""
echo -e "${BLUE}Join commands have been saved to:${NC}"
echo "   - Worker: /tmp/worker-join-command.sh"
echo "   - Control Plane: /tmp/control-plane-join-command.sh"
echo ""
