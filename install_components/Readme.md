# Kubernetes Node Setup Script

Automated setup script for preparing Linux nodes for Kubernetes cluster deployment.

**⚠️ IMPORTANT: Open and read the script first! All usage examples and parameters are documented inside the script comments.**

## Overview

This bash script automates the installation and configuration of all necessary components for a Kubernetes node. It handles host configuration, dependency installation, kernel module setup, and installation of key Kubernetes components with automatic version management.

## Features

- **Automatic package manager detection** - Supports APT (Debian/Ubuntu), YUM (CentOS/RHEL), and DNF (Fedora/RHEL/CentOS)
- **Comprehensive component installation**:
    - runc (v1.1.12)
    - containerd (1.7.19)
    - kubelet (v1.30.4)
    - etcd (v3.5.12)
    - kubectl (v1.30.4)
    - crictl (v1.30.0)
    - kubeadm (v1.30.4)
- **System configuration**:
    - Hostname setting
    - Kernel module loading (overlay, br_netfilter)
    - Sysctl optimization for Kubernetes
    - Dependency management
- **Smart installation** - Checks existing versions and updates only if needed
- **Systemd integration** - Each component has its own installation service
- **Verification** - Comprehensive post-installation checks

## Prerequisites

- Linux system (tested on Ubuntu 20.04+, CentOS 8+, RHEL 8+)
- Root/sudo privileges
- Internet connectivity
- At least 2GB RAM, 2 CPU cores, 20GB disk space recommended

## Usage

1. **Download the script**:
   ```bash
   curl -O https://raw.githubusercontent.com/your-repo/setup_node.sh
   chmod +x setup_node.sh