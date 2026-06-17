#!/bin/bash
# ============================================================================
# 01. Install Prerequisites
# - System updates
# - Docker
# - Go
# - Essential tools (git, curl, wget, jq, etc.)
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="01-prerequisites"
source "$SCRIPT_DIR/common.sh"

# Versions
GO_VERSION="1.22.5"
DOCKER_VERSION=""  # Latest

print_header "Step 1: Install Prerequisites"

check_root

# ============================================================================
# System Update
# ============================================================================
log_step "Updating system packages..."
run_cmd "Update apt cache" "apt-get update"
run_cmd "Upgrade packages" "apt-get upgrade -y"

# ============================================================================
# Essential Tools
# ============================================================================
log_step "Installing essential tools..."

ESSENTIAL_PACKAGES=(
    apt-transport-https
    ca-certificates
    curl
    wget
    gnupg
    lsb-release
    software-properties-common
    git
    jq
    yq
    make
    gcc
    build-essential
    unzip
    vim
    htop
    net-tools
    bash-completion
    socat
    conntrack
    ipset
    ipvsadm
)

run_cmd "Install essential packages" "apt-get install -y ${ESSENTIAL_PACKAGES[*]}"

# ============================================================================
# Disable Swap (Required for Kubernetes)
# ============================================================================
log_step "Disabling swap..."
run_cmd "Disable swap" "swapoff -a"
run_cmd "Remove swap from fstab" "sed -i '/swap/d' /etc/fstab"

# ============================================================================
# Kernel Modules and Sysctl
# ============================================================================
log_step "Configuring kernel modules..."

cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF

run_cmd "Load overlay module" "modprobe overlay"
run_cmd "Load br_netfilter module" "modprobe br_netfilter"

log_step "Configuring sysctl parameters..."

cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

run_cmd "Apply sysctl settings" "sysctl --system"

# ============================================================================
# Docker Installation
# ============================================================================
log_step "Installing Docker..."

if check_command docker; then
    log_info "Docker already installed, skipping..."
else
    # Remove old versions
    run_cmd_allow_fail "Remove old Docker versions" \
        "apt-get remove -y docker docker-engine docker.io containerd runc"

    # Add Docker GPG key
    run_cmd "Create keyrings directory" "mkdir -p /etc/apt/keyrings"
    run_cmd "Download Docker GPG key" \
        "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"

    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    run_cmd "Update apt cache" "apt-get update"
    run_cmd "Install Docker" "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

    # Configure Docker daemon
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m"
    },
    "storage-driver": "overlay2"
}
EOF

    run_cmd "Enable Docker service" "systemctl enable docker"
    run_cmd "Start Docker service" "systemctl start docker"
fi

# Verify Docker
run_cmd "Verify Docker installation" "docker version"

# ============================================================================
# Containerd Configuration (for Kubernetes)
# ============================================================================
log_step "Configuring containerd for Kubernetes..."

run_cmd "Generate containerd default config" "containerd config default > /etc/containerd/config.toml"

# Enable SystemdCgroup
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

run_cmd "Restart containerd" "systemctl restart containerd"
run_cmd "Enable containerd" "systemctl enable containerd"

# ============================================================================
# Go Installation
# ============================================================================
log_step "Installing Go $GO_VERSION..."

if check_command go; then
    INSTALLED_GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    log_info "Go already installed: $INSTALLED_GO_VERSION"
else
    GO_TARBALL="go${GO_VERSION}.linux-amd64.tar.gz"
    GO_URL="https://golang.org/dl/$GO_TARBALL"

    run_cmd "Download Go" "wget -q $GO_URL -O /tmp/$GO_TARBALL"
    run_cmd "Extract Go" "tar -C /usr/local -xzf /tmp/$GO_TARBALL"
    run_cmd "Cleanup Go tarball" "rm /tmp/$GO_TARBALL"

    # Set up Go environment
    cat >> /etc/profile.d/go.sh << 'EOF'
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin
EOF

    source /etc/profile.d/go.sh
fi

# Add Go to current session
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin

run_cmd "Verify Go installation" "go version"

# ============================================================================
# Helm Installation
# ============================================================================
log_step "Installing Helm..."

if check_command helm; then
    log_info "Helm already installed, skipping..."
else
    run_cmd "Download Helm installer" "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get_helm.sh"
    run_cmd "Install Helm" "bash /tmp/get_helm.sh"
    run_cmd "Cleanup Helm installer" "rm /tmp/get_helm.sh"
fi

run_cmd "Verify Helm installation" "helm version"

# ============================================================================
# kubectl Installation (Pre-install for convenience)
# ============================================================================
log_step "Installing kubectl..."

if check_command kubectl; then
    log_info "kubectl already installed, skipping..."
else
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    run_cmd "Download kubectl" \
        "curl -LO https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    run_cmd "Install kubectl" "install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl"
    run_cmd "Cleanup kubectl binary" "rm kubectl"
fi

run_cmd "Verify kubectl installation" "kubectl version --client"

# ============================================================================
# Summary
# ============================================================================
INSTALLED_ITEMS=(
    "$(docker version --format '{{.Server.Version}}' 2>/dev/null && echo ' Docker')"
    "$(go version 2>/dev/null)"
    "$(helm version --short 2>/dev/null && echo ' Helm')"
    "$(kubectl version --client --short 2>/dev/null && echo ' kubectl')"
)

print_summary "Installed Components" "${INSTALLED_ITEMS[@]}"

print_footer "success" "Prerequisites Installation"

log_info ""
log_info "Next step: Run 02.install-kubernetes.sh"
log_info ""
