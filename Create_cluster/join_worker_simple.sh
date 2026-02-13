#!/bin/bash
# Simple Kubernetes Worker Node Join Script
# This script expects the join command to be provided as an argument
# or reads it from /tmp/worker-join-command.sh (copied from master)
#
# Usage Option 1: sudo ./join_worker_simple.sh
# (reads from /tmp/worker-join-command.sh)
#
# Usage Option 2: sudo ./join_worker_simple.sh "kubeadm join 192.168.1.100:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxx"

set -e # Stop on error

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

print_header "Simple Kubernetes Worker Join"

# Get join command
if [ -n "$1" ]; then
    JOIN_COMMAND="$1"
    print_info "Using join command from argument"
elif [ -f "/tmp/worker-join-command.sh" ]; then
    JOIN_COMMAND=$(cat /tmp/worker-join-command.sh)
    print_info "Using join command from /tmp/worker-join-command.sh"
else
    print_error "No join command provided. Either:"
    echo "  1. Pass it as argument: sudo $0 'kubeadm join ...'"
    echo "  2. Copy /tmp/worker-join-command.sh from master node"
    exit 1
fi

# Verify it's a valid join command
if [[ ! "$JOIN_COMMAND" == *"kubeadm join"* ]]; then
    print_error "Invalid join command. Must start with 'kubeadm join'"
fi

echo "Join command: $JOIN_COMMAND"
echo ""

# =========================================
# Configure containerd
# =========================================
print_header "Configuring containerd"

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

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

systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd
print_success "containerd configured and running"

# =========================================
# Configure kubelet
# =========================================
print_header "Configuring kubelet"

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

mkdir -p /etc/systemd/system/kubelet.service.d

cat <<EOF > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF

systemctl daemon-reload
systemctl enable kubelet
print_success "kubelet configured"

# =========================================
# Clean old configuration
# =========================================
print_header "Cleaning old configuration"

rm -rf /etc/kubernetes /var/lib/kubelet 2>/dev/null || true
print_success "Clean up complete"

# =========================================
# Join cluster
# =========================================
print_header "Joining cluster"

print_info "Executing: $JOIN_COMMAND"
eval "$JOIN_COMMAND"

if [ $? -eq 0 ]; then
    print_success "Successfully joined the cluster!"
    echo ""
    echo -e "${BLUE}On the master node, run:${NC}"
    echo -e "  ${YELLOW}kubectl get nodes${NC}"
    echo ""
else
    print_error "Failed to join cluster. Check logs: journalctl -u kubelet -f"
fi
