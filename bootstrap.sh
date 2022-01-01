#!/bin/bash
set -uexo pipefail

server_type=cx21
image=ubuntu-20.04
location=fsn1
ssh_key=mine
loadbalancer_type=lb11
network_cidr=10.96.0.0/14
pod_cidr=10.98.0.0/15
service_cidr=10.97.0.0/16
kube_version=1.21.8

[[ -f .env ]] && source .env

if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
  echo "HCLOUD_TOKEN not set"
  exit 1
fi
export HCLOUD_TOKEN

# Creates a placement group to ensure master nodes 
function setup_placement_group() {
  if ! hcloud placement-group describe cluster >/dev/null 2>&1; then
    hcloud placement-group create --name cluster --type spread
  fi
}

function setup_loadbalancer() {
  if ! hcloud load-balancer describe cluster >/dev/null 2>&1; then
    hcloud load-balancer create --algorithm-type round_robin --location $location --name cluster --type $loadbalancer_type
  fi

  for port in 80:32080:--proxy-protocol 443:32443:--proxy-protocol 6443:6443:; do
    listen_port=$(echo $port | cut -d':' -f1)
    dest_port=$(echo $port | cut -d':' -f2)
    flags=$(echo $port | cut -d':' -f3)

    if [[ -z "$(hcloud load-balancer describe cluster -o json | jq ".services | map(select(.listen_port == $listen_port)) | .[]")" ]]; then
      hcloud load-balancer add-service cluster --destination-port "$dest_port" --listen-port "$listen_port" --protocol tcp "$flags"
    fi
  done
}

function setup_network() {
  if ! hcloud network describe cluster >/dev/null 2>&1; then
    hcloud network create --ip-range $network_cidr --name cluster
  fi
  if [[ -z "$(hcloud network describe cluster -o json | jq ".subnets | map(select(.ip_range == \"$network_cidr\")) | .[]")" ]]; then
    hcloud network add-subnet cluster --ip-range $network_cidr --network-zone eu-central --type cloud
  fi
}

function attach_lb_to_network() {
  network_id=$(hcloud network describe cluster -o json | jq .id)

  if [[ -z "$(hcloud load-balancer describe cluster -o json | jq ".private_net | map(select(.network == $network_id)) | .[]")" ]]; then
    hcloud load-balancer attach-to-network cluster --network cluster
  fi
}

function setup_firewall() {
  if ! hcloud firewall describe cluster >/dev/null 2>&1; then
    hcloud firewall create --name cluster --rules-file - <<RULES
[
  {
    "description": "SSH",
    "destination_ips": [],
    "direction": "in",
    "port": "22",
    "protocol": "tcp",
    "source_ips": [
      "0.0.0.0/0",
      "::/0"
    ]
  },
  {
    "description": "Wireguard",
    "destination_ips": [],
    "direction": "in",
    "port": "51871",
    "protocol": "udp",
    "source_ips": [
      "0.0.0.0/0",
      "::/0"
    ]
  }
]
RULES
  fi
}

function setup_control_node() {
  if ! hcloud server describe "$1" >/dev/null 2>&1; then
    hcloud server create \
      --name "$1" \
      --type $server_type \
      --placement-group cluster \
      --ssh-key $ssh_key \
      --image $image \
      --location $location \
      --firewall cluster \
      --network cluster
    ssh-keygen -R "$(hcloud server ip "$1")"
  fi

  server_id=$(hcloud server describe "$1" -o "format={{.ID}}")

  if [[ -z "$(hcloud load-balancer describe cluster -o json | jq ".targets | map(select(.server.id == $server_id)) | .[]")" ]]; then
    hcloud load-balancer add-target cluster --server "$1" --use-private-ip
  fi

  server_ip=$(hcloud server ip "$1")
  until ssh -o StrictHostKeyChecking=accept-new root@"$server_ip" echo hi mom >/dev/null 2>&1; do sleep 1; done

  ssh -T root@"$server_ip" kube_version=$kube_version bash <<-"INIT"
    set -ueo pipefail
    export DEBIAN_FRONTEND=noninteractive

    if ! command -v docker >/dev/null 2>&1; then
      apt-get update
      apt-get install -y ca-certificates curl gnupg lsb-release
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io
      echo '{"exec-opts":["native.cgroupdriver=systemd"]}' > /etc/docker/daemon.json
      systemctl restart docker.service
    fi
    if ! command -v kubeadm >/dev/null 2>&1; then
      apt-get update
      apt-get install -y apt-transport-https ca-certificates curl
      curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
      echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list
      apt-get update
      apt-get install -y kubelet=$kube_version-00 kubeadm=$kube_version-00 kubectl=$kube_version-00
      apt-mark hold kubelet kubeadm kubectl
    fi
INIT
}

setup_placement_group &
setup_loadbalancer &
setup_network &
setup_firewall &

# shellcheck disable=SC2046
wait $(jobs -p)

attach_lb_to_network

loadbalancer_ip=$(hcloud load-balancer describe cluster -o json | jq -r .public_net.ipv4.ip)

for name in cluster{1..3}; do
  setup_control_node "$name" &
done

# shellcheck disable=SC2046
wait $(jobs -p)

cluster_master=""
for name in cluster{1..3}; do
  if [[ "$(hcloud server ssh $name '[[ -f /etc/kubernetes/admin.conf ]] && echo "yes" || echo "no"')" == "yes" ]]; then
    cluster_master=$name
  fi
done

if [[ -z "$cluster_master" ]]; then
  private_ip=$(hcloud server describe cluster1 -o json | jq -r '.private_net[0].ip')
  cat > /tmp/kubeadm <<KUBEADM
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
clusterName: personal
controlPlaneEndpoint: $loadbalancer_ip
networking:
  serviceSubnet: $service_cidr
  podSubnet: $pod_cidr
kubernetesVersion: $kube_version
controllerManager:
  extraArgs:
    bind-address: 0.0.0.0
scheduler:
  extraArgs:
    bind-address: 0.0.0.0
etcd:
  local:
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $private_ip
nodeRegistration:
  kubeletExtraArgs:
    node-ip: $private_ip
    cloud-provider: external
KUBEADM

  hcloud server ssh cluster1 "kubeadm init --config /dev/stdin" </tmp/kubeadm
  cluster_master=cluster1
fi

if ! kubectl config get-contexts | grep personal-admin@personal >/dev/null 2>&1; then
  mkdir -p ~/.kube
  hcloud server ssh $cluster_master 'cat /etc/kubernetes/admin.conf | sed -e s/kubernetes-admin/personal-admin/' > ~/.kube/personal.conf
  [[ -f $HOME/.kube/config ]] && mv "$HOME"/.kube/config{,.bak}
  KUBECONFIG=$HOME/.kube/config.bak:$HOME/.kube/personal.conf kubectl config view --raw > "$HOME"/.kube/config
  rm ~/.kube/personal.conf
fi

discovery_token_hash=sha256:$(hcloud server ssh $cluster_master -T "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'")
join_token=$(hcloud server ssh $cluster_master -T <<"TOKEN"
  token=$(kubeadm token list | grep authentication | cut -d' ' -f1 | tail -n1)
  if [[ -z "$token" ]]; then
    token=$(kubeadm token generate)
  fi
  echo $token
TOKEN
)

cert_key=$(hcloud server ssh $cluster_master -T <<"CERTS"
  set -ueo pipefail
  cert_key=$(kubeadm certs certificate-key)
  kubeadm init phase upload-certs --upload-certs --certificate-key $cert_key >/dev/null
  echo $cert_key
CERTS
)

for name in cluster{1..3}; do
  private_ip=$(hcloud server describe $name -o json | jq -r '.private_net[0].ip')
  cat > /tmp/kubeadm <<KUBEADM
apiVersion: kubeadm.k8s.io/v1beta2
kind: JoinConfiguration
controlPlane:
  localAPIEndpoint:
    advertiseAddress: $private_ip
  certificateKey: $cert_key
discovery:
  bootstrapToken:
    apiServerEndpoint: $loadbalancer_ip:6443
    token: $join_token
    caCertHashes: [$discovery_token_hash]
nodeRegistration:
  kubeletExtraArgs:
    node-ip: $private_ip
    cloud-provider: external
KUBEADM

  hcloud server ssh $name "if [[ ! -f /etc/kubernetes/kubelet.conf ]]; then kubeadm join --config /dev/stdin; fi" < /tmp/kubeadm
done

kube_ctx="--context=personal-admin@personal"
kubectl="kubectl $kube_ctx"

if ! $kubectl -n kube-system get deploy/cilium-operator >/dev/null 2>&1; then
  cilium install $kube_ctx --encryption=wireguard
fi

$kubectl -n kube-system create secret generic hcloud --from-literal=HCLOUD_TOKEN=$HCLOUD_TOKEN -o yaml --dry-run=client \
  | $kubectl apply -f-

$kubectl -n kube-system create secret generic discovery-token-hash --from-literal=hash="$discovery_token_hash" -o yaml --dry-run=client \
  | $kubectl apply -f-

$kubectl -n kube-system create secret generic age-key --from-file=age-key.txt=<(age -d -i ~/.ssh/id_ed25519 < age-key.txt) -o yaml --dry-run=client \
  | $kubectl apply -f-

if ! $kubectl -n flux-system get namespace flux-system >/dev/null 2>&1; then
  flux install $kube_ctx --toleration-keys=node-role.kubernetes.io/master
fi

if ! $kubectl -n flux-system get gitrepo personal-infrastructure >/dev/null 2>&1; then
  flux create source git personal-infrastructure \
    $kube_ctx \
    --url https://github.com/samcday/personal-infrastructure.git \
    --branch main
fi

if ! $kubectl -n flux-system get kustomization personal-infrastructure >/dev/null 2>&1; then
  flux create kustomization personal-infrastructure \
    $kube_ctx \
    --source personal-infrastructure \
    --path .
fi

$kubectl get nodes
