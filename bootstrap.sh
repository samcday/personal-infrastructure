#!/bin/bash
set -ueo pipefail

server_type=cpx21
image=ubuntu-20.04
location=fsn1
ssh_key=mine
loadbalancer_type=lb11

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

  for port in 80 443 6443; do
    if [[ -z "$(hcloud load-balancer describe cluster -o json | jq ".services | map(select(.destination_port == $port)) | .[]")" ]]; then
      hcloud load-balancer add-service cluster --destination-port $port --listen-port $port --protocol tcp
    fi
  done
}

function setup_control_node() {
  if ! hcloud server describe "$1" >/dev/null 2>&1; then
    hcloud server create --name "$1" --type $server_type --placement-group cluster --ssh-key $ssh_key --image $image --location $location
    ssh-keygen -R "$(hcloud server ip "$1")"
  fi

  server_id=$(hcloud server describe "$1" -o "format={{.ID}}")

  if [[ -z "$(hcloud load-balancer describe cluster -o json | jq ".targets | map(select(.server.id == $server_id)) | .[]")" ]]; then
    hcloud load-balancer add-target cluster --server "$1"
  fi

  server_ip=$(hcloud server ip "$1")
  until ssh -o StrictHostKeyChecking=accept-new root@"$server_ip" echo hi mom >/dev/null 2>&1; do sleep 1; done

  result=$(ssh -T root@"$server_ip" <<-"INIT"
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
      apt-get install -y kubelet kubeadm kubectl
      apt-mark hold kubelet kubeadm kubectl
    fi
INIT
)
}

loadbalancer_ip=$(hcloud load-balancer describe cluster -o json | jq -r .public_net.ipv4.ip)

setup_placement_group &
setup_loadbalancer &

# shellcheck disable=SC2046
wait $(jobs -p)

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
  CP_ENDPOINT=$loadbalancer_ip envsubst < kubeadm.yml | hcloud server ssh cluster1 \
    'cat > kubeadm.yml && kubeadm init --config kubeadm.yml --skip-token-print'
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
  token=$(kubeadm token list | grep authentication | cut -d' ' -f1)
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
  hcloud server ssh $name -T <<-JOIN
    set -ueo pipefail
    if [[ -f /etc/kubernetes/kubelet.conf ]]; then
      exit 0
    fi

    kubeadm join "$loadbalancer_ip":6443 --control-plane --certificate-key $cert_key --discovery-token-ca-cert-hash=$discovery_token_hash --token $join_token
JOIN
done

if ! kubectl --context=personal-admin@personal -n kube-system get deploy/cilium-operator >/dev/null 2>&1; then
  cilium install --context=personal-admin@personal --encryption=wireguard
fi

flux install --context=personal-admin@personal --toleration-keys=node-role.kubernetes.io/master
flux create source git personal-infrastructure \
  --context=personal-admin@personal \
  --url https://github.com/samcday/personal-infrastructure.git \
  --branch main
flux create kustomization personal-infrastructure \
  --context=personal-admin@personal \
  --source personal-infrastructure \
  --path .

kubectl --context=personal-admin@personal get nodes
