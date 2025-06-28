#!/bin/bash
# Script to set up CRI-O as container runtime and install Kubernetes tools under Ubuntu 22.04 and later or Debian 12 and later
# Reference: https://kubernetes.io/docs/setup/production-environment/container-runtimes/#cri-o
# Reference: https://cri-o.io/
# Reference: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
# Reference: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
# Reference: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/kubelet-integration/

# Always upgrade first your global system before running this bash script 'sudo apt update && sudo apt upgrade -y'

# Define version for packages needed
KUBERNETES_VERSION=v1.33
CRIO_VERSION=v1.33

sudo apt update
sudo apt install -y jq

# Setting up CRI-O and Kubernetes prerequisites
cat <<- EOF | sudo tee /etc/modules-load.d/crio.conf
    overlay
    br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Setup required sysctl params, these persist across reboots
cat <<- EOF | sudo tee /etc/sysctl.d/99-kubernetes-crio.conf
    net.bridge.bridge-nf-call-iptables  = 1
    net.ipv4.ip_forward                 = 1
    net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# Install Kubernetes tools dependencies
sudo apt install -y curl apt-transport-https ca-certificates software-properties-common

# Install CRI-O dependencies
# libseccomp2 typically pre-installed in Debian 12, Ubuntu 22.04 and later, as it’s a dependency for many system components, runc comes with CRI-O installation
# sudo apt install -y libseccomp2 runc

# Add the Kubernetes repository GPG Key
curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add the Kubernetes repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    
# Add the CRI-O repository GPG Key
curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

# Add the CRI-O repository
echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/cri-o.list

# Install CRI-O
sudo apt update
sudo apt install -y cri-o kubelet kubeadm kubectl

# Start and enable CRI-O
sudo systemctl start crio.service
sudo systemctl enable crio.service
sudo systemctl daemon-reload

# Configure CRI-O  (if needed)
#sudo mkdir -p /etc/crio
#cat <<- EOF | sudo tee /etc/crio/crio.conf
#[crio]
#[crio.runtime]
#default_runtime = "runc"
#[crio.runtime.runtimes.runc]
#runtime_type = "oci"
#runtime_path = "/usr/bin/runc"  # Use system runc path
#[crio.runtime.runtimes.runc.options]
#systemd_cgroup = true
#EOF

# Disable AppArmor for runc  (if needed)
#sudo ln -s /etc/apparmor.d/runc /etc/apparmor.d/disable/
#sudo apparmor_parser -R /etc/apparmor.d/runc
#
#touch /tmp/crio.txt
#exit
