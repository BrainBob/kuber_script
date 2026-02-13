#!/bin/bash
# Automatic Kubenets node setup
# Usage: sudo ./setup_node.sh <name node>

set -y # Stop on error

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Проверка прав
if [ "$EUID" -ne 0 ]; then 
    echo "Run the script with sudo: sudo $0"
    exit 1
fi

# Getting the hostname
if [ -z "$1" ]; then
    echo "Usage: sudo $0 <name node>"
    echo "Example: sudo $0 master-1"
    exit 1
fi

# Disable Swapoff
swapoff -a

HOST_NAME="$1"
CLUSTER_NAME="test-cluster"
BASE_DOMAIN="test.com"
CLUSTER_DOMAIN="cluster.local"
FULL_HOST_NAME="${HOST_NAME}.${CLUSTER_NAME}.${BASE_DOMAIN}"

print_header "Node setup: $HOST_NAME"
echo "Full name: $FULL_HOST_NAME"
echo "Cluster: $CLUSTER_NAME"
echo "Domen: $BASE_DOMAIN"
echo ""

echo "#####################################"

# ============================ 
# Setting the hostname
# ============================ 
print_header "1. Setting the hostname "
print_step " Setting the hostname: $FULL_HOST_NAME"

hostnamectl set-hostname ${FULL_HOST_NAME}

# Update /etc/hosts
if ! grep -q "$FULL_HOST_NAME" /etc/hosts; then
    echo "127.0.0.1" $FULL_HOST_NAME $HOST_NAME >> /etc/hosts
fi

print_success "Hostname set: $(hostname)"

echo "##########################################"

# =========================================
# 2. Definition of a package manager
# =========================================
print_header "2. Definition of a package manager"

if command -v apt &> /dev/null; then
    PKG_MANAGER="apt"
    UPDATE_CMD="apt update -y"
    INSTALL_CMD="apt install -y"
    CONNTRACK_PKG="conntrack"
    print_step "Detected Debian/Ubuntu (apt)"

elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
    UPDATE_CMD="yum update -y"
    INSTALL_CMD="yum install -y"
    CONNTRACK_PKG="conntrack"
    print_step "Detected Сentos\RHEL (yum)"

elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
    UPDATE_CMD="dnf update -y"
    INSTALL_CMD="dnf install -y"
    CONNTRACK_PKG="conntrack"
    print_step "Detected RHEL\Centos\Fedora (dnf)"

else
    print_error "Unable to locate package manager"
fi

print_success "Package Manager: $PKG_MANAGER"

echo "##########################################"

# =========================================
# 3. Installing dependencies
# =========================================
print_header "3. Installing dependencies"

print_step "Updating repositories...."
$UPDATE_CMD

print_step "Installing packages...."
$INSTALL_CMD $CONNTRACK_PKG socat jq tree curl wget

print_success "Dependencies are established"

echo "#########################################"

# =========================================
# 4. Installing kernel modules
# =========================================
print_header "4. Installing kernel modules"

print_step "creating a module config..."
cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF

print_step "loading modules"
modprobe overlay
modprobe br_netfilter

print_success " Kernel modules are configured"

echo "######################################"

# =========================================
# 5. Setting sysctl
# =========================================
print_header "5. Setting sysctl"

print_step "Setting bridge netfilter"
cat > /etc/sysctl.d/99-br-netfilter.conf << EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

print_step "Setting ip-forwarding"
cat > /etc/sysctl.d/99-network.conf << EOF
net.ipv4.ip_forward=1
EOF

print_step "Applying settings...."
sysctl --system

print_success "Sysctl settings applied"

echo "#############################################"

# =========================================
# 6. Installing components
# =========================================
print_header "6.1 Installing components - runc"

print_step "Install runc"
print_step "Creating a working directory"
mkdir -p /etc/default/runc

print_step "Environment variable settings"
cat <<EOF > /etc/default/runc/download.env
COMPONENT_VERSION="v1.1.12"
REPOSITORY="https://github.com/opencontainers/runc/releases/download"
EOF

print_step "Download instructions"
cat <<"EOF" > /etc/default/runc/download-script.sh
#!/bin/bash
set -Eeuo pipefail


COMPONENT_VERSION="${COMPONENT_VERSION:-v1.1.12}"
REPOSITORY="${REPOSITORY:-https://github.com/opencontainers/runc/releases/download}"
PATH_BIN="${REPOSITORY}/${COMPONENT_VERSION}/runc.amd64"
PATH_SHA256="${REPOSITORY}/${COMPONENT_VERSION}/runc.sha256sum"
INSTALL_PATH="/usr/local/bin/runc"

LOG_TAG="runc-installer"
TMP_DIR="$(mktemp -d)"

logger -t "$LOG_TAG" "[INFO] Checking current runc version..."

CURRENT_VERSION=$($INSTALL_PATH --version 2>/dev/null | head -n1 | awk '{print $NF}') || CURRENT_VERSION="none"
COMPONENT_VERSION_CLEAN=$(echo "$COMPONENT_VERSION" | sed 's/^v//')

logger -t "$LOG_TAG" "[INFO] Current: $CURRENT_VERSION, Target: $COMPONENT_VERSION_CLEAN"

if [[ "$CURRENT_VERSION" != "$COMPONENT_VERSION_CLEAN" ]]; then
  logger -t "$LOG_TAG" "[INFO] Download URL: $PATH_BIN"
  logger -t "$LOG_TAG" "[INFO] Updating runc to version $COMPONENT_VERSION..."

  cd "$TMP_DIR"
  logger -t "$LOG_TAG" "[INFO] Working directory: $PWD"

  logger -t "$LOG_TAG" "[INFO] Downloading runc..."
  curl -fsSL -o runc.amd64 "$PATH_BIN" || { logger -t "$LOG_TAG" "[ERROR] Failed to download runc"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Downloading checksum file..."
  curl -fsSL -o runc.sha256sum "$PATH_SHA256" || { logger -t "$LOG_TAG" "[ERROR] Failed to download checksum file"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Verifying checksum..."
  grep "runc.amd64" runc.sha256sum | sha256sum -c - || { logger -t "$LOG_TAG" "[ERROR] Checksum verification failed!"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Installing runc..."
  install -m 755 runc.amd64 "$INSTALL_PATH"

  logger -t "$LOG_TAG" "[INFO] runc successfully updated to $COMPONENT_VERSION."
  rm -rf "$TMP_DIR"

else
  logger -t "$LOG_TAG" "[INFO] runc is already up to date. Skipping installation."
fi
EOF

print_step "Setting up rights"
chmod +x /etc/default/runc/download-script.sh

print_step "download service"
cat <<EOF > /usr/lib/systemd/system/runc-install.service
[Unit]
Description=Install and update in-cloud component runc
After=network.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/runc/download.env
ExecStart=/bin/bash -c "/etc/default/runc/download-script.sh"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

print_step "Autoload"
systemctl enable runc-install.service
systemctl start runc-install.service

print_success "Runc installation is complete."

echo "############################################"

print_header "6.2 installation of components - containerd"

print_step "Creating a working directory"
mkdir -p /etc/default/containerd

print_step "Setting Environment Variables"
cat <<EOF > /etc/default/containerd/download.env
COMPONENT_VERSION="1.7.19"
REPOSITORY="https://github.com/containerd/containerd/releases/download"
EOF

print_step "Download instructions"
cat <<"EOF" > /etc/default/containerd/download-script.sh
#!/bin/bash
set -Eeuo pipefail


COMPONENT_VERSION="${COMPONENT_VERSION:-1.7.19}"
REPOSITORY="${REPOSITORY:-https://github.com/containerd/containerd/releases/download}"
PATH_BIN="${REPOSITORY}/v${COMPONENT_VERSION}/containerd-${COMPONENT_VERSION}-linux-amd64.tar.gz"
PATH_SHA256="${REPOSITORY}/v${COMPONENT_VERSION}/containerd-${COMPONENT_VERSION}-linux-amd64.tar.gz.sha256sum"
INSTALL_PATH="/usr/local/bin/"


LOG_TAG="containerd-installer"
TMP_DIR="$(mktemp -d)"

logger -t "$LOG_TAG" "[INFO] Checking current containerd version..."

CURRENT_VERSION=$($INSTALL_PATH/containerd --version 2>/dev/null | awk '{print $3}' | sed 's/v//') || CURRENT_VERSION="none"
COMPONENT_VERSION_CLEAN=$(echo "$COMPONENT_VERSION" | sed 's/^v//')

logger -t "$LOG_TAG" "[INFO] Current: $CURRENT_VERSION, Target: $COMPONENT_VERSION_CLEAN"

if [[ "$CURRENT_VERSION" != "$COMPONENT_VERSION_CLEAN" ]]; then
  logger -t "$LOG_TAG" "[INFO] Download URL: $PATH_BIN"
  logger -t "$LOG_TAG" "[INFO] Updating containerd to version $COMPONENT_VERSION_CLEAN..."

  cd "$TMP_DIR"
  logger -t "$LOG_TAG" "[INFO] Working directory: $PWD"

  logger -t "$LOG_TAG" "[INFO] Downloading containerd..."
  curl -fsSL -o "containerd-${COMPONENT_VERSION}-linux-amd64.tar.gz" "$PATH_BIN" || { logger -t "$LOG_TAG" "[ERROR] Failed to download containerd"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Downloading checksum file..."
  curl -fsSL -o "containerd.sha256sum" "$PATH_SHA256" || { logger -t "$LOG_TAG" "[ERROR] Failed to download checksum file"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Verifying checksum..."
  sha256sum -c containerd.sha256sum | grep 'OK' || { logger -t "$LOG_TAG" "[ERROR] Checksum verification failed!"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Extracting files..."
  tar -C "$TMP_DIR" -xvf "containerd-${COMPONENT_VERSION}-linux-amd64.tar.gz"

  logger -t "$LOG_TAG" "[INFO] Installing binaries..."
  install -m 755 "$TMP_DIR/bin/containerd" $INSTALL_PATH
  install -m 755 "$TMP_DIR/bin/containerd-shim"* $INSTALL_PATH
  install -m 755 "$TMP_DIR/bin/ctr" $INSTALL_PATH

  logger -t "$LOG_TAG" "[INFO] Containerd successfully updated to $COMPONENT_VERSION."
  rm -rf "$TMP_DIR"

else
  logger -t "$LOG_TAG" "[INFO] Containerd is already up to date. Skipping installation."
fi
EOF

print_step "Setting up rights"
chmod +x /etc/default/containerd/download-script.sh

print_step "Download service"
cat <<EOF > /usr/lib/systemd/system/containerd-install.service
[Unit]
Description=Install and update in-cloud component containerd
After=network.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/containerd/download.env
ExecStart=/bin/bash -c "/etc/default/containerd/download-script.sh"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

print_step "Autoload"
systemctl enable containerd-install.service
systemctl start containerd-install.service

print_success "Containerd installation is complete."

echo "###############################################"

print_header "6.3  Install - kubelet"

print_step "Creating a working directory"
mkdir -p /etc/default/kubelet

print_step "Environment variable settings"
cat <<EOF > /etc/default/kubelet/download.env
COMPONENT_VERSION="v1.30.4"
REPOSITORY="https://dl.k8s.io"
EOF

print_step "Download instructions"
cat <<"EOF" > /etc/default/kubelet/download-script.sh
#!/bin/bash
set -Eeuo pipefail


COMPONENT_VERSION="${COMPONENT_VERSION:-v1.30.4}"
REPOSITORY="${REPOSITORY:-https://dl.k8s.io}"
PATH_BIN="${REPOSITORY}/${COMPONENT_VERSION}/bin/linux/amd64/kubelet"
PATH_SHA256="${REPOSITORY}/${COMPONENT_VERSION}/bin/linux/amd64/kubelet.sha256"
INSTALL_PATH="/usr/local/bin/kubelet"


LOG_TAG="kubelet-installer"
TMP_DIR="$(mktemp -d)"

logger -t "$LOG_TAG" "[INFO] Checking current kubelet version..."

CURRENT_VERSION=$($INSTALL_PATH --version 2>/dev/null | awk '{print $2}' | sed 's/v//') || CURRENT_VERSION="none"
COMPONENT_VERSION_CLEAN=$(echo "$COMPONENT_VERSION" | sed 's/^v//')

logger -t "$LOG_TAG" "[INFO] Current: $CURRENT_VERSION, Target: $COMPONENT_VERSION_CLEAN"

if [[ "$CURRENT_VERSION" != "$COMPONENT_VERSION_CLEAN" ]]; then
  logger -t "$LOG_TAG" "[INFO] Download URL: $PATH_BIN"
  logger -t "$LOG_TAG" "[INFO] Updating kubelet to version $COMPONENT_VERSION_CLEAN..."

  cd "$TMP_DIR"
  logger -t "$LOG_TAG" "[INFO] Working directory: $PWD"

  logger -t "$LOG_TAG" "[INFO] Downloading kubelet..."
  curl -fsSL -o kubelet "$PATH_BIN" || { logger -t "$LOG_TAG" "[ERROR] Failed to download kubelet"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Downloading checksum file..."
  curl -fsSL -o kubelet.sha256sum "$PATH_SHA256" || { logger -t "$LOG_TAG" "[ERROR] Failed to download checksum file"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Verifying checksum..."
  awk '{print $1"  kubelet"}' kubelet.sha256sum | sha256sum -c - || { logger -t "$LOG_TAG" "[ERROR] Checksum verification failed!"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Installing kubelet..."
  install -m 755 kubelet "$INSTALL_PATH"

  logger -t "$LOG_TAG" "[INFO] kubelet successfully updated to $COMPONENT_VERSION_CLEAN."
  rm -rf "$TMP_DIR"

else
  logger -t "$LOG_TAG" "[INFO] kubelet is already up to date. Skipping installation."
fi
EOF


print_step "Setting up rights"
chmod +x /etc/default/kubelet/download-script.sh

print_step "Download service"
cat <<EOF > /usr/lib/systemd/system/kubelet-install.service
[Unit]
Description=Install and update kubelet
After=network.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/kubelet/download.env
ExecStart=/bin/bash -c "/etc/default/kubelet/download-script.sh"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

print_step "Autoload"
systemctl enable kubelet-install.service
systemctl start kubelet-install.service

print_success "Kubelet installation is complete."

echo "#############################################"

print_header "6.4 Install - Etcd"

print_step "Creating a working directory"
mkdir -p /etc/default/etcd

print_step "Environment variable settings"
cat <<EOF > /etc/default/etcd/download.env
COMPONENT_VERSION="v3.5.12"
REPOSITORY="https://github.com/etcd-io/etcd/releases/download"
EOF

print_step "Download instructions"
cat <<"EOF" > /etc/default/etcd/download-script.sh
#!/bin/bash
set -Eeuo pipefail


COMPONENT_VERSION="${COMPONENT_VERSION:-v3.5.12}"
REPOSITORY="${REPOSITORY:-https://github.com/etcd-io/etcd/releases/download}"
PATH_BIN="${REPOSITORY}/${COMPONENT_VERSION}/etcd-${COMPONENT_VERSION}-linux-amd64.tar.gz"
PATH_SHA256="${REPOSITORY}/${COMPONENT_VERSION}/SHA256SUMS"
INSTALL_PATH="/usr/local/bin/"


LOG_TAG="etcd-installer"
TMP_DIR="$(mktemp -d)"

logger -t "$LOG_TAG" "[INFO] Checking current etcd version..."

CURRENT_VERSION=$($INSTALL_PATH/etcd --version 2>/dev/null | grep 'etcd Version:' | awk '{print $3}' | sed 's/v//') || CURRENT_VERSION="none"
COMPONENT_VERSION_CLEAN=$(echo "$COMPONENT_VERSION" | sed 's/^v//')

logger -t "$LOG_TAG" "[INFO] Current: $CURRENT_VERSION, Target: $COMPONENT_VERSION_CLEAN"

if [[ "$CURRENT_VERSION" != "$COMPONENT_VERSION_CLEAN" ]]; then
  logger -t "$LOG_TAG" "[INFO] Download URL: $PATH_BIN"
  logger -t "$LOG_TAG" "[INFO] Updating etcd to version $COMPONENT_VERSION_CLEAN..."

  cd "$TMP_DIR"
  logger -t "$LOG_TAG" "[INFO] Working directory: $PWD"

  logger -t "$LOG_TAG" "[INFO] Downloading etcd..."
  curl -fsSL -o "etcd-${COMPONENT_VERSION}-linux-amd64.tar.gz" "$PATH_BIN" || { logger -t "$LOG_TAG" "[ERROR] Failed to download etcd"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Downloading checksum file..."
  curl -fsSL -o "etcd.sha256sum" "$PATH_SHA256" || { logger -t "$LOG_TAG" "[ERROR] Failed to download checksum file"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Verifying checksum..."
  grep "etcd-${COMPONENT_VERSION}-linux-amd64.tar.gz" etcd.sha256sum | sha256sum -c - || { logger -t "$LOG_TAG" "[ERROR] Checksum verification failed!"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Extracting files..."
  tar -C "$TMP_DIR" -xvf "etcd-${COMPONENT_VERSION}-linux-amd64.tar.gz"

  logger -t "$LOG_TAG" "[INFO] Installing binaries..."
  install -m 755 "$TMP_DIR/etcd-${COMPONENT_VERSION}-linux-amd64/etcd" $INSTALL_PATH
  install -m 755 "$TMP_DIR/etcd-${COMPONENT_VERSION}-linux-amd64/etcdctl" $INSTALL_PATH
  install -m 755 "$TMP_DIR/etcd-${COMPONENT_VERSION}-linux-amd64/etcdutl" $INSTALL_PATH

  logger -t "$LOG_TAG" "[INFO] etcd successfully updated to $COMPONENT_VERSION_CLEAN."
  rm -rf "$TMP_DIR"

else
  logger -t "$LOG_TAG" "[INFO] etcd is already up to date. Skipping installation."
fi
EOF

print_step "Setting up rights"
chmod +x /etc/default/etcd/download-script.sh

print_step "Download service"
cat <<EOF > /usr/lib/systemd/system/etcd-install.service
[Unit]
Description=Install and update in-cloud component etcd
After=network.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/etcd/download.env
ExecStart=/bin/bash -c "/etc/default/etcd/download-script.sh"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

print_step "Autoload"
systemctl enable etcd-install.service
systemctl start etcd-install.service

print_success "Etcd installation is complete."

echo "###########################################"

print_header "6.4 Install - kubectl"

print_step "Creating a working directory"
mkdir -p /etc/default/kubectl

print_step "Environment variable settings"
cat <<EOF > /etc/default/kubectl/download.env
COMPONENT_VERSION="v1.30.4"
REPOSITORY="https://dl.k8s.io"
EOF

print_step "Download instructions"
cat <<"EOF" > /etc/default/kubectl/download-script.sh
#!/bin/bash
set -Eeuo pipefail


COMPONENT_VERSION="${COMPONENT_VERSION:-v1.30.4}"
REPOSITORY="${REPOSITORY:-https://dl.k8s.io}"
PATH_BIN="${REPOSITORY}/${COMPONENT_VERSION}/bin/linux/amd64/kubectl"
PATH_SHA256="${REPOSITORY}/${COMPONENT_VERSION}/bin/linux/amd64/kubectl.sha256"
INSTALL_PATH="/usr/local/bin/kubectl"


LOG_TAG="kubectl-installer"
TMP_DIR="$(mktemp -d)"

logger -t "$LOG_TAG" "[INFO] Checking current kubectl version..."

CURRENT_VERSION=$($INSTALL_PATH version -o json --client=true 2>/dev/null | jq -r '.clientVersion.gitVersion' | sed 's/^v//') || CURRENT_VERSION="none"
COMPONENT_VERSION_CLEAN=$(echo "$COMPONENT_VERSION" | sed 's/^v//')

logger -t "$LOG_TAG" "[INFO] Current: $CURRENT_VERSION, Target: $COMPONENT_VERSION_CLEAN"

if [[ "$CURRENT_VERSION" != "$COMPONENT_VERSION_CLEAN" ]]; then
  logger -t "$LOG_TAG" "[INFO] Download URL: $PATH_BIN"
  logger -t "$LOG_TAG" "[INFO] Updating kubectl to version $COMPONENT_VERSION_CLEAN..."

  cd "$TMP_DIR"
  logger -t "$LOG_TAG" "[INFO] Working directory: $PWD"

  logger -t "$LOG_TAG" "[INFO] Downloading kubectl..."
  curl -fsSL -o kubectl "$PATH_BIN" || { logger -t "$LOG_TAG" "[ERROR] Failed to download kubectl"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Downloading checksum file..."
  curl -fsSL -o kubectl.sha256sum "$PATH_SHA256" || { logger -t "$LOG_TAG" "[ERROR] Failed to download checksum file"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Verifying checksum..."
  awk '{print $1"  kubectl"}' kubectl.sha256sum | sha256sum -c - || { logger -t "$LOG_TAG" "[ERROR] Checksum verification failed!"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Installing kubectl..."
  install -m 755 kubectl "$INSTALL_PATH"

  logger -t "$LOG_TAG" "[INFO] kubectl successfully updated to $COMPONENT_VERSION_CLEAN."
  rm -rf "$TMP_DIR"

else
  logger -t "$LOG_TAG" "[INFO] kubectl is already up to date. Skipping installation."
fi
EOF

print_step "Setting up rights"
chmod +x /etc/default/kubectl/download-script.sh

print_step "Download service"
cat <<EOF > /usr/lib/systemd/system/kubectl-install.service
[Unit]
Description=Install and update kubectl
After=network.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/kubectl/download.env
ExecStart=/bin/bash -c "/etc/default/kubectl/download-script.sh"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

print_step "Autoload"
systemctl enable kubectl-install.service
systemctl start kubectl-install.service

print_success "Kubectl installation is complete."

echo "############################################################"

print_header "6.5 Install - crictl"

print_step "Creating a working directory"
mkdir -p /etc/default/crictl

print_step "Environment variable settings"
cat <<EOF > /etc/default/crictl/download.env
COMPONENT_VERSION="v1.30.0"
REPOSITORY="https://github.com/kubernetes-sigs/cri-tools/releases/download"
EOF

print_step "Download instructions"
cat <<"EOF" > /etc/default/crictl/download-script.sh
#!/bin/bash
set -Eeuo pipefail


COMPONENT_VERSION="${COMPONENT_VERSION:-v1.30.0}"
REPOSITORY="${REPOSITORY:-https://github.com/kubernetes-sigs/cri-tools/releases/download}"
PATH_BIN="${REPOSITORY}/${COMPONENT_VERSION}/crictl-${COMPONENT_VERSION}-linux-amd64.tar.gz"
PATH_SHA256="${REPOSITORY}/${COMPONENT_VERSION}/crictl-${COMPONENT_VERSION}-linux-amd64.tar.gz.sha256"
INSTALL_PATH="/usr/local/bin/crictl"


LOG_TAG="crictl-installer"
TMP_DIR="$(mktemp -d)"

logger -t "$LOG_TAG" "[INFO] Checking current crictl version..."

CURRENT_VERSION=$($INSTALL_PATH --version 2>/dev/null | awk '{print $3}' | sed 's/v//') || CURRENT_VERSION="none"
COMPONENT_VERSION_CLEAN=$(echo "$COMPONENT_VERSION" | sed 's/^v//')

logger -t "$LOG_TAG" "[INFO] Current: $CURRENT_VERSION, Target: $COMPONENT_VERSION_CLEAN"

if [[ "$CURRENT_VERSION" != "$COMPONENT_VERSION_CLEAN" ]]; then
  logger -t "$LOG_TAG" "[INFO] Download URL: $PATH_BIN"
  logger -t "$LOG_TAG" "[INFO] Updating crictl to version $COMPONENT_VERSION_CLEAN..."

  cd "$TMP_DIR"
  logger -t "$LOG_TAG" "[INFO] Working directory: $PWD"

  logger -t "$LOG_TAG" "[INFO] Downloading crictl..."
  curl -fsSL -o crictl.tar.gz "$PATH_BIN" || { logger -t "$LOG_TAG" "[ERROR] Failed to download crictl"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Downloading checksum file..."
  curl -fsSL -o crictl.sha256sum "$PATH_SHA256" || { logger -t "$LOG_TAG" "[ERROR] Failed to download checksum file"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Verifying checksum..."
  awk '{print $1"  crictl.tar.gz"}' crictl.sha256sum | sha256sum -c - || { logger -t "$LOG_TAG" "[ERROR] Checksum verification failed!"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Extracting files..."
  tar -C "$TMP_DIR" -xvf crictl.tar.gz

  logger -t "$LOG_TAG" "[INFO] Installing crictl..."
  install -m 755 "$TMP_DIR/crictl" "$INSTALL_PATH"

  logger -t "$LOG_TAG" "[INFO] crictl successfully updated to $COMPONENT_VERSION_CLEAN."
  rm -rf "$TMP_DIR"

else
  logger -t "$LOG_TAG" "[INFO] crictl is already up to date. Skipping installation."
fi
EOF

print_step "Setting up rights"
chmod +x /etc/default/crictl/download-script.sh

print_step "Download service"
cat <<EOF > /usr/lib/systemd/system/crictl-install.service
[Unit]
Description=Install and update in-cloud component crictl
After=network.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/crictl/download.env
ExecStart=/bin/bash -c "/etc/default/crictl/download-script.sh"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

print_step "Autoload"
systemctl enable crictl-install.service
systemctl start crictl-install.service

print_success "Crictl installation is complete."

echo "######################################"

print_header "6.5 Install - kubeadm"

print_step "Creating a working directory"
mkdir -p /etc/default/kubeadm

print_step "Environment variable settings"
cat <<EOF > /etc/default/kubeadm/download.env
COMPONENT_VERSION="v1.30.4"
REPOSITORY="https://dl.k8s.io"
EOF

print_step "Download instructions"
cat <<"EOF" > /etc/default/kubeadm/download-script.sh
#!/bin/bash
set -Eeuo pipefail


COMPONENT_VERSION="${COMPONENT_VERSION:-v1.30.4}"
REPOSITORY="${REPOSITORY:-https://dl.k8s.io}"
PATH_BIN="${REPOSITORY}/${COMPONENT_VERSION}/bin/linux/amd64/kubeadm"
PATH_SHA256="${REPOSITORY}/${COMPONENT_VERSION}/bin/linux/amd64/kubeadm.sha256"
INSTALL_PATH="/usr/local/bin/kubeadm"


LOG_TAG="kubeadm-installer"
TMP_DIR="$(mktemp -d)"

logger -t "$LOG_TAG" "[INFO] Checking current kubeadm version..."

CURRENT_VERSION=$($INSTALL_PATH version -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' | sed 's/^v//') || CURRENT_VERSION="none"
COMPONENT_VERSION_CLEAN=$(echo "$COMPONENT_VERSION" | sed 's/^v//')

logger -t "$LOG_TAG" "[INFO] Current: $CURRENT_VERSION, Target: $COMPONENT_VERSION_CLEAN"

if [[ "$CURRENT_VERSION" != "$COMPONENT_VERSION_CLEAN" ]]; then
  logger -t "$LOG_TAG" "[INFO] Download URL: $PATH_BIN"
  logger -t "$LOG_TAG" "[INFO] Updating kubeadm to version $COMPONENT_VERSION_CLEAN..."

  cd "$TMP_DIR"
  logger -t "$LOG_TAG" "[INFO] Working directory: $PWD"

  logger -t "$LOG_TAG" "[INFO] Downloading kubeadm..."
  curl -fsSL -o kubeadm "$PATH_BIN" || { logger -t "$LOG_TAG" "[ERROR] Failed to download kubeadm"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Downloading checksum file..."
  curl -fsSL -o kubeadm.sha256sum "$PATH_SHA256" || { logger -t "$LOG_TAG" "[ERROR] Failed to download checksum file"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Verifying checksum..."
  awk '{print $1"  kubeadm"}' kubeadm.sha256sum | sha256sum -c - || { logger -t "$LOG_TAG" "[ERROR] Checksum verification failed!"; exit 1; }

  logger -t "$LOG_TAG" "[INFO] Installing kubeadm..."
  install -m 755 kubeadm "$INSTALL_PATH"

  logger -t "$LOG_TAG" "[INFO] kubeadm successfully updated to $COMPONENT_VERSION_CLEAN."
  rm -rf "$TMP_DIR"

else
  logger -t "$LOG_TAG" "[INFO] kubeadm is already up to date. Skipping installation."
fi
EOF

print_step "Setting up rights"
chmod +x /etc/default/kubeadm/download-script.sh

print_step "Download service"
cat <<EOF > /usr/lib/systemd/system/kubeadm-install.service
[Unit]
Description=Install and update kubeadm
After=network.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/kubeadm/download.env
ExecStart=/bin/bash -c "/etc/default/kubeadm/download-script.sh"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

print_step "Autoload"
systemctl enable kubeadm-install.service
systemctl start kubeadm-install.service

print_success "Kubeadm installation is complete."

echo "########################################"


# =========================================
# . Checking the installation
# =========================================
print_header ". Checking the installation"

echo ""
echo "Final check:"
echo "##########################################"

echo -n "Name host: "
if [ "{$hostname)" = $FULL_HOST_NAME ]; then
    echo -e "$(hostname) ✓${NC}"
else
    echo -e "$(hostname) ✗${NC}"
fi

echo -n "Check packet: "
if command -v connstrack &> /dev/null && \
   command -v socat &> /dev/null && \
   command -v jq &> /dev/bull && \
   command -v tree &> /dev/null; then
   echo -e "${GREEN}All install ✓${NC}"
else
   echo -e "${RED}not all install ✗${NC}"
fi

echo "###########################################"

echo -n "Checking modules: "
if lsmod | grep -q overlay && lsmod | grep -q br_netfilter; then
    echo -e "${GREEN}loaded ✓${NC}"
else
    echo -e "${RED}not loaded ✗${NC}"
fi

echo "##########################################"

echo -n "Checking sysctl: "
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; then
    echo -e "${GREEN}configured ✓${NC}"
else
    echo -e "${RED}not configured ✗${NC}"
fi

echo "#####################################"

echo -n "Checking runc: "
if journalctl -t runc-installer -n 5 2>/dev/null | grep -q "successfully updated"; then
   echo "✓ Installation found in log"
fi

if [ -f /usr/local/bin/runc ]; then
    echo "✓File available"
    ls -lh /usr/local/bin/runc | grep runc
else
    echo "✗File not found"
fi

if command -v runc &> /dev/null; then 
    echo "✓ Version runc:"
    runc --version
else
    echo "✗ runc not installed"
fi        

echo "########################################"


echo -n "Checking containerd: "
if journalctl -t containerd-installer -n 5 2>/dev/null | grep -q "successfully updated"; then
   echo "✓ Installation found in log"
fi

if [ -f /usr/local/bin/containerd ]; then
    echo "✓File available"
    ls -lh /usr/local/bin/containerd | grep containerd
else
    echo "✗File not found"
fi

if command -v containerd &> /dev/null; then 
    echo "✓ Version containerd:"
    containerd --version
else
    echo "✗ containerd not installed"
fi 

echo "#########################################"

echo -n "Checking kubelet: "
if journalctl -t kubelet-installer -n 5 2>/dev/null | grep -q "successfully updated"; then
   echo "✓ Installation found in log"
fi

if [ -f /usr/local/bin/kubelet ]; then
    echo "✓File available"
    ls -lh /usr/local/bin/kubelet | grep kubelet
else
    echo "✗File not found"
fi

if command -v kubelet &> /dev/null; then 
    echo "✓ Version kubelet:"
    kubelet --version
else
    echo "✗ kubelet not installed"
fi 

echo "#######################################"

echo -n "Checking Etcd: "
if journalctl -t etcd-installer -n 5 2>/dev/null | grep -q "successfully updated"; then
   echo "✓ Installation found in log"
fi

if [ -f /usr/local/bin/etcd ]; then
    echo "✓File available"
    ls -lh /usr/local/bin/etcd | grep etcd
else
    echo "✗File not found"
fi

if command -v etcd &> /dev/null; then 
    echo "✓ Version etcd:"
    etcd --version
else
    echo "✗ etcd not installed"
fi 

echo "#######################################"

echo -n "Checking kubectl: "
if journalctl -t kubectl-installer -n 5 2>/dev/null | grep -q "successfully updated"; then
   echo "✓ Installation found in log"
fi

if [ -f /usr/local/bin/kubectl ]; then
    echo "✓File available"
    ls -lh /usr/local/bin/kubectl | grep kubectl
else
    echo "✗File not found"
fi

if command -v kubectl &> /dev/null; then 
    echo "✓ Version kubectl:"
    kubectl --version
else
    echo "✗ kubectl not installed"
fi

echo "########################################"

echo -n "Checking crictl: "
if journalctl -t crictl-installer -n 5 2>/dev/null | grep -q "successfully updated"; then
   echo "✓ Installation found in log"
fi

if [ -f /usr/local/bin/crictl ]; then
    echo "✓File available"
    ls -lh /usr/local/bin/crictl | grep crictl
else
    echo "✗File not found"
fi

if command -v crictl &> /dev/null; then 
    echo "✓ Version crictl:"
    crictl --version
else
    echo "✗ crictl not installed"
fi

echo "###########################################"

echo -n "Checking kubeadm: "
if journalctl -t kubeadm-installer -n 5 2>/dev/null | grep -q "successfully updated"; then
   echo "✓ Installation found in log"
fi

if [ -f /usr/local/bin/kubeadm ]; then
    echo "✓File available"
    ls -lh /usr/local/bin/kubeadm | grep kubeadm
else
    echo "✗File not found"
fi

if command -v kubeadm &> /dev/null; then 
    echo "✓ Version kubeadm:"
    kubeadm --version
else
    echo "✗ kubeadm not installed"
fi

print_success "Installation script completed."
