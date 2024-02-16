#!/bin/bash

set -Exeuo pipefail

{ echo "export LANGUAGE=en_US.UTF-8"; echo "export LC_ALL=en_US.UTF-8"; echo "export LANG=en_US.UTF-8"; } >> .bashrc

export LANGUAGE=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

sudo apt-get update

# check required port
nc 127.0.0.1 6443 || echo "Port is available" # should fail then port is available

PRIVATE_IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
# ensure hostname entry exists in /etc/hosts
echo "$PRIVATE_IP $(hostname)" | sudo tee -a /etc/hosts

# load overlay and bridge traffic filter modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# check and install if modules are missing
lsmod | grep br_netfilter || sudo modprobe overlay && sudo modprobe br_netfilter

# enable required sysctl params
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# ensure cgroup v1 is installed. # Check cgroup version Refer: https://unix.stackexchange.com/questions/471476/how-do-i-check-cgroup-v2-is-installed-on-my-machine
grep -v cgroup2 /proc/filesystems

# Steps to install docker engine from: https://docs.docker.com/engine/install/ubuntu/

# Remove any previously installed docker
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove $pkg || true; done

# Add Docker's official GPG key:
sleep 30
sudo apt-get update
sudo apt-get install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository to Apt sources:
echo \
  "deb [arch=\"$(dpkg --print-architecture)\" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  \"$(. /etc/os-release && echo "$VERSION_CODENAME")\" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io


# If Not systemd driver then
# https://stackoverflow.com/a/65870152/746528
if sudo docker info | grep -i 'Cgroup Driver' | grep -i systemd
then
  echo "No change required"
else
  sudo tee /etc/docker/daemon.json <<EOF
  {
    "exec-opts": ["native.cgroupdriver=systemd"]
  }
EOF
  sudo systemctl restart docker
fi

# install cri-dockerd shim. Refer: https://computingforgeeks.com/install-mirantis-cri-dockerd-as-docker-engine-shim-for-kubernetes/
VER=$(curl -s https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest|grep tag_name | cut -d '"' -f 4|sed 's/v//g')

wget https://github.com/Mirantis/cri-dockerd/releases/download/v"${VER}"/cri-dockerd-"${VER}".amd64.tgz
tar xvf cri-dockerd-"${VER}".amd64.tgz
sudo mv cri-dockerd/cri-dockerd /usr/local/bin/

cri-dockerd --version

wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.service
wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.socket
sudo mv cri-docker.socket cri-docker.service /etc/systemd/system/
sudo sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service

sudo systemctl daemon-reload
sudo systemctl enable cri-docker.service
sudo systemctl enable --now cri-docker.socket

sudo systemctl is-active cri-docker.socket

# install kubelet, kubeadm etc
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.24/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.24/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y unzip
sudo apt-get install -y jq
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Setup cluster kubeadm

cat > kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/cri-dockerd.sock
localAPIEndpoint:
  advertiseAddress: ${PRIVATE_IP}
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: "192.168.0.0/16"
EOF

sudo kubeadm init phase preflight --v=5 --config kubeadm-config.yaml

sudo kubeadm init phase certs all --v=5 --config kubeadm-config.yaml

sudo kubeadm init phase kubeconfig all --v=5 --config kubeadm-config.yaml

mkdir -p "$HOME"/.kube
sudo cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

sudo kubeadm init phase kubelet-start --v=5 --config kubeadm-config.yaml

sudo kubeadm init phase kubelet-finalize all --v=5 --config kubeadm-config.yaml

