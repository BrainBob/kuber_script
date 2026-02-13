#!/bin/bash
# Kubernetes Worker Node Join Script
# Usage: sudo ./join_worker.sh <master-ip> <token> <ca-cert-hash>
# Example: sudo ./join_worker.sh 192.168.1.100 abcdef.0123456789abcdef sha256:1234567890abcdef...

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

# Parse arguments
if [ $# -lt 3 ]; then
    echo "Usage: sudo $0 <master-ip> <token> <ca-cert-hash>"
    echo ""
    echo "Example:"
    echo "  sudo $0 192.168.1.100 abcdef.0123456789abcdef sha256:1234567890abcdef..."
    echo ""
    echo "Or provide the full join command as a single argument:"
    echo "  sudo $0 'kubeadm join 192.168.1.100:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxx'"
    exit 1
fi

# Check if first argument is a full join command
if [[ "$1" == *"kubeadm join"* ]]; then
    JOIN_COMMAND="$1"
    MASTER_IP=$(echo "$JOIN_COMMAND" | grep -oP '\d+\.\d+\.\d+\.\d+:\d+' | cut -d: -f1)
else
    MASTER_IP="$1"
    TOKEN="$2"
    CA_CERT_HASH="$3"
    JOIN_COMMAND="kubeadm join ${MASTER_IP}:6443 --token ${TOKEN} --discovery-token-ca-cert-hash ${CA_CERT_HASH}"
fi

print_header "Kubernetes Worker Node Join"
echo "Master IP: $MASTER_IP"
echo "Node: $(hostname -f)"
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
        print_error "$component is not installed. Run setup_node.sh first!"
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

print_step "Checking connectivity to master node..."
if ping -c 1 -W 2 $MASTER_IP &> /dev/null; then
    print_success "Master node $MASTER_IP is reachable"
else
    print_error "Cannot reach master node $MASTER_IP"
fi

print_step "Checking master API server..."
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$MASTER_IP/6443" 2>/dev/null; then
    print_success "Master API server is accessible on port 6443"
else
    print_error "Cannot connect to master API server on $MASTER_IP:6443"
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

print_success "kubelet configured (will start after kubeadm join)"

# =========================================
# 4. Clean up old cluster configuration (if exists)
# =========================================
print_header "4. Cleaning up old configuration"

if [ -d "/etc/kubernetes" ]; then
    print_step "Removing old Kubernetes configuration..."
    rm -rf /etc/kubernetes
    print_success "Old configuration removed"
fi

if [ -d "/var/lib/kubelet" ]; then
    print_step "Removing old kubelet data..."
    rm -rf /var/lib/kubelet
    print_success "Old kubelet data removed"
fi

# =========================================
# 5. Join the cluster
# =========================================
print_header "5. Joining Kubernetes cluster"

print_step "Executing join command..."
print_info "This may take a minute..."

echo "$JOIN_COMMAND" > /tmp/join-command.sh
chmod +x /tmp/join-command.sh

eval "$JOIN_COMMAND"

if [ $? -eq 0 ]; then
    print_success "Successfully joined the cluster!"
else
    print_error "Failed to join the cluster"
fi

# =========================================
# 6. Verification
# =========================================
print_header "6. Verification"

print_step "Waiting for kubelet to start..."
sleep 5

if systemctl is-active --quiet kubelet; then
    print_success "kubelet is running"
else
    print_error "kubelet is not running"
fi

print_step "Checking kubelet status..."
systemctl status kubelet --no-pager -l | head -n 20

# =========================================
# Final summary
# =========================================
print_header "Worker Node Join Complete!"

echo ""
echo -e "${GREEN}Worker node joined successfully!${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. On the master node, verify this worker has joined:"
echo -e "   ${YELLOW}kubectl get nodes${NC}"
echo ""
echo "2. Check node status (should become Ready after CNI is configured):"
echo -e "   ${YELLOW}kubectl get nodes -o wide${NC}"
echo ""
echo "3. Check running pods on this node:"
echo -e "   ${YELLOW}kubectl get pods -A -o wide | grep $(hostname)${NC}"
echo ""
echo -e "${BLUE}Troubleshooting:${NC}"
echo "If the node doesn't appear, check kubelet logs:"
echo -e "   ${YELLOW}journalctl -u kubelet -f${NC}"
echo ""
