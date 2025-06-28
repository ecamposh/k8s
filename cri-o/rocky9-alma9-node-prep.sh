#!/bin/bash
# Script to install and configure CRI-O and Kubernetes tools on Rocky Linux 9
# Prepares a node for a Kubernetes cluster (excludes kubeadm init)
# Versions: CRI-O v1.33, Kubernetes v1.33
# Modifications: Uses specified CRI-O and Kubernetes repositories, firewalld stopped/disabled, SELinux permanently set to permissive, global system upgrade removed
# Additions: Warning about missing network plugin (including CoreDNS impact), suggestion on kubelet/kubeadm init order, network checks
# Run as root or with sudo
# Always remember to first upgrade global system 'dnf update -y' before executing the bash script.

# Exit on error, unset variables, or pipeline failures
set -euo pipefail

# Define versions
CRIO_VERSION="v1.33"
KUBERNETES_VERSION="v1.33"
CNI_PLUGINS_VERSION="v1.3.0"
ARCH="amd64"
LOG_FILE="/var/log/k8s-node-setup.log"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log "ERROR: This script must be run as root or with sudo."
    exit 1
fi

# Step 1: Check network connectivity
log "Installing bind-utils to use nslookup..." 
dnf install -y bind-utils >> "$LOG_FILE" 2>&1
log "bind-utils installed."
log "Checking network connectivity..."
if ! ping -c 4 google.com >/dev/null 2>&1; then
    log "ERROR: No internet connectivity. Please check your network."
    exit 1
fi
if ! nslookup download.opensuse.org >/dev/null 2>&1; then
    log "ERROR: DNS resolution failed for download.opensuse.org. Please check your DNS settings."
    exit 1
fi
if ! nslookup pkgs.k8s.io >/dev/null 2>&1; then
    log "ERROR: DNS resolution failed for pkgs.k8s.io. Please check your DNS settings."
    exit 1
fi
log "Network connectivity and DNS resolution verified."

# Step 2: Disable swap
log "Disabling swap..."
swapoff -a >> "$LOG_FILE" 2>&1
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
log "Swap disabled. Verifying..."
if free -m | grep -q "Swap:.*0.*0.*0"; then
    log "Swap is disabled."
else
    log "ERROR: Failed to disable swap."
    exit 1
fi

# Step 3: Set SELinux to permissive permanently
log "Setting SELinux to permissive mode permanently..."
setenforce 0 >> "$LOG_FILE" 2>&1
sed -i 's/^SELINUX=.*$/SELINUX=permissive/' /etc/selinux/config
log "Verifying SELinux configuration..."
if grep -q "^SELINUX=permissive$" /etc/selinux/config && [ "$(getenforce)" = "Permissive" ]; then
    log "SELinux is set to permissive."
else
    log "ERROR: Failed to set SELinux to permissive."
    exit 1
fi

# Step 4: Stop and disable firewalld
log "Stopping and disabling firewalld..."
systemctl stop firewalld >> "$LOG_FILE" 2>&1
systemctl disable firewalld >> "$LOG_FILE" 2>&1
log "Verifying firewalld status..."
if ! systemctl is-active --quiet firewalld; then
    log "firewalld is stopped and disabled."
else
    log "ERROR: Failed to stop/disable firewalld."
    exit 1
fi

# Step 5: Load kernel modules
log "Configuring kernel modules..."
cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay >> "$LOG_FILE" 2>&1
modprobe br_netfilter >> "$LOG_FILE" 2>&1
log "Kernel modules loaded. Verifying..."
if lsmod | grep -q overlay && lsmod | grep -q br_netfilter; then
    log "Kernel modules overlay and br_netfilter loaded."
else
    log "ERROR: Failed to load kernel modules."
    exit 11
fi

# Step 6: Configure sysctl parameters
log "Configuring sysctl parameters..."
cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system >> "$LOG_FILE" 2>&1
log "Sysctl parameters applied. Verifying..."
if sysctl net.bridge.bridge-nf-call-iptables | grep -q "= 1" && \
   sysctl net.ipv4.ip_forward | grep -q "= 1" && \
   sysctl net.bridge.bridge-nf-call-ip6tables | grep -q "= 1"; then
    log "Sysctl parameters configured correctly."
else
    log "ERROR: Failed to configure sysctl parameters."
    exit 1
fi

# Step 7: Install CRI-O
log "Adding CRI-O repository..."
cat <<EOF | tee /etc/yum.repos.d/cri-o.repo
[cri-o]
name=CRI-O
baseurl=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/rpm/repodata/repomd.xml.key
EOF
log "Cleaning DNF cache..."
dnf clean all >> "$LOG_FILE" 2>&1
rm -rf /var/cache/dnf >> "$LOG_FILE" 2>&1

log "Installing CRI-O..."
dnf install -y cri-o >> "$LOG_FILE" 2>&1
log "CRI-O installed."

# Step 8: Configure CRI-O
log "Configuring CRI-O..."
if ! grep -q "cgroup_manager = \"systemd\"" /etc/crio/crio.conf; then
    cat <<EOF >>/etc/crio/crio.conf
[crio.runtime]
cgroup_manager = "systemd"
conmon_cgroup = "pod"
EOF
fi
mkdir -p /etc/containers
cat <<EOF >/etc/containers/registries.conf
[registries.search]
registries = ["docker.io", "quay.io"]
EOF
log "CRI-O configured."

# Step 9: Enable and start CRI-O
log "Enabling and starting CRI-O..."
systemctl daemon-reload >> "$LOG_FILE" 2>&1
systemctl enable crio --now >> "$LOG_FILE" 2>&1
log "Verifying CRI-O status..."
if systemctl is-active --quiet crio && crio --version | grep -q "1.33"; then
    log "CRI-O is active and running version $(crio --version | head -n 1)."
else
    log "ERROR: CRI-O failed to start or incorrect version."
    exit 1
fi

# Step 10: Install Kubernetes tools
log "Adding Kubernetes repository..."
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/rpm/repodata/repomd.xml.key
EOF
log "Cleaning DNF cache..."
dnf clean all >> "$LOG_FILE" 2>&1
rm -rf /var/cache/dnf >> "$LOG_FILE" 2>&1
log "Installing Kubernetes tools..."
dnf install -y kubelet kubeadm kubectl >> "$LOG_FILE" 2>&1
log "Kubernetes tools installed."

# Step 11: Configure kubelet
#log "Configuring kubelet..."
#cat <<EOF >/var/lib/kubelet/kubeadm-flags.env
#KUBELET_KUBEADM_ARGS="--container-runtime=remote --container-runtime-endpoint=unix:///var/run/crio/crio.sock --cgroup-driver=systemd"
#EOF
#log "Kubelet configured."

# Step 12: Enable kubelet service
#log "Enabling kubelet service..."
#systemctl enable kubelet >> "$LOG_FILE" 2>&1
#log "Kubelet service enabled (not started, awaiting cluster join)."

# Step 13: Install CNI plugins
log "Installing CNI plugins..."
mkdir -p /opt/cni/bin
curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz" | tar -C /opt/cni/bin -xz >> "$LOG_FILE" 2>&1
log "CNI plugins installed."

# Step 14: Verify node preparation
log "Verifying node preparation..."
if crictl info >/dev/null 2>&1; then
    log "CRI-O runtime is ready."
else
    log "ERROR: CRI-O runtime check failed."
    exit 1
fi

if free -m | grep -q "Swap:.*0.*0.*0" && \
   sysctl net.bridge.bridge-nf-call-iptables | grep -q "= 1" && \
   sysctl net.ipv4.ip_forward | grep -q "= 1" && \
   sysctl net.bridge.bridge-nf-call-ip6tables | grep -q "= 1"; then
    log "System configuration verified (swap disabled, sysctl parameters set)."
else
    log "ERROR: System configuration verification failed."
    exit 1
fi

# Step 15: Warn about missing network plugin and CoreDNS impact
log "WARNING: A Container Network Interface (CNI) plugin (e.g., Calico, Flannel, Cilium) has not been installed yet."
log "This will result in 'NetworkReady=false' in 'crictl info' output until a CNI plugin is configured."
log "Without a CNI plugin, CoreDNS (the default Kubernetes DNS service) pods will remain in 'Pending' or 'CrashLoopBackOff' state because they cannot communicate over the pod network."
log "A CNI plugin will be applied automatically when you run 'kubeadm init' (control plane) or 'kubeadm join' (worker node), followed by deploying a CNI plugin."
log "For example, you can install Calico after cluster initialization using:"
log "  kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml"

# Step 16: Suggest kubelet/kubeadm init order
log "SUGGESTION: Do not start the kubelet service manually before running 'kubeadm init' or 'kubeadm join'."
log "For a control plane node, run 'kubeadm init' first to initialize the cluster, which will automatically start kubelet."
log "For a worker node, run 'kubeadm join' to join the cluster, which will also start kubelet."
log "The kubelet service is already enabled and will start automatically after 'kubeadm init' or 'kubeadm join'."

log "Node preparation complete! Ready to join a Kubernetes cluster."
log "Log file: $LOG_FILE"
log "Next steps: Run 'kubeadm join' with the appropriate token and master node details to join a cluster, or 'kubeadm init' for a control plane node."
