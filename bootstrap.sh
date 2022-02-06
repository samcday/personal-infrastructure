#!/bin/bash
set -uexo pipefail

# This script bootstraps a 3 node Kubernetes cluster in Hetzner Cloud.
# The cluster nodes will be in a private network, fronted by a load balancer, and protected by a firewall.
# The script is idempotent, it can be run repeatedly until completely successful.
# This means it can also be used to partially rebuild an existing cluster.
. _setup.sh

# Create a placement group to ensure the 3 nodes are spread across multiple failure zones.
if ! hcloud placement-group describe cluster >/dev/null 2>&1; then
  hcloud placement-group create --name cluster --type spread
fi

echo placement group configured

# Create a private network for intra-cluster traffic.
if ! hcloud network describe cluster -o json >/tmp/network.json 2>/dev/null; then
  hcloud network create --ip-range $network_cidr --name cluster
  hcloud network describe cluster -o json >/tmp/network.json
fi

# Subnets in Hetzner Cloud are not yet feature complete, so we just create one spanning the whole network.
if [[ -z "$(jq ".subnets | map(select(.ip_range == \"$subnet_cidr\")) | .[]" < /tmp/network.json)" ]]; then
  hcloud network add-subnet cluster --ip-range $subnet_cidr --network-zone eu-central --type cloud
fi

echo network configured

# Create a load balancer. It will provide HA for Kubernetes API Server, as well as regular HTTP(S) ingress.
if ! hcloud load-balancer describe cluster -o json > /tmp/lb.json 2>/dev/null; then
  hcloud load-balancer create --algorithm-type round_robin --location $location --name cluster --type $loadbalancer_type
  hcloud load-balancer describe cluster -o json > /tmp/lb.json
fi

# The load balancer is attached to the private network, this way the nodes do not need to listen on the public 'net.
network_id=$(jq .id < /tmp/network.json)
if [[ -z "$(jq ".private_net | map(select(.network == $network_id)) | .[]" < /tmp/lb.json)" ]]; then
  hcloud load-balancer attach-to-network cluster --network cluster
fi

# HTTP(S) traffic uses proxy protocol, so that ingress-nginx in the cluster knows where the original request came from.
for port in 80:32080:--proxy-protocol 443:32443:--proxy-protocol 6443:31443:; do
  listen_port=$(echo $port | cut -d':' -f1)
  dest_port=$(echo $port | cut -d':' -f2)
  flags=$(echo $port | cut -d':' -f3)

  if [[ -z "$(jq ".services | map(select(.listen_port == $listen_port)) | .[]" < /tmp/lb.json)" ]]; then
    hcloud load-balancer add-service cluster --destination-port "$dest_port" --listen-port "$listen_port" --protocol tcp $flags
  fi
done 

# The load balancer sends traffic to nodes based on labels. The base 3 nodes will have a "cluster" label.
# The cluster will also be autoscaled, using cluster-autoscaler. The worker nodes have a different label.
labels=(cluster hcloud/node-group=pool)
for label in "${labels[@]}"; do
  if [[ -z "$(jq ".targets | map(select(.label_selector.selector==\"$label\")) | .[]" < /tmp/lb.json)" ]]; then
    hcloud load-balancer add-target cluster --label-selector $label --use-private-ip
  fi
done

echo loadbalancer configured

# The firewall protects all cluster nodes and is heavily restricted.
if ! hcloud firewall describe cluster -o json > /tmp/firewall.json 2>/dev/null; then
  hcloud firewall create --name cluster
  hcloud firewall describe cluster > /tmp/firewall.json
fi

# Similar to the load balancer, the firewall is attached to label selectors matching the base + autoscaled nodes.
for label in "${labels[@]}"; do
  if [[ -z "$(jq ".applied_to | map(select(.label_selector.selector==\"$label\")) | .[]" < /tmp/firewall.json)" ]]; then
    hcloud firewall apply-to-resource cluster --type label_selector --label-selector $label
  fi
done

# In its operational state, all external traffic comes in via the load balancer. The LB talks to the nodes via the
# private network. Intra-cluster traffic (pods talking to pods/services, etc) also routes through the private network.
# As such, the firewall typically requires no inbound rules at all (drop all traffic from external sources).
# It's only during bootstrapping that we need direct SSH access to the nodes. Later, a Tailscale subnet router will
# be deployed into the cluster to access internal services / nodes. Whilst not strictly necessary, UDP 41641 is opened
# to allow efficient NAT traversal (and avoid using a relay).
ports=(22:tcp:TempSSH 41641:udp:Tailscale)
for port in "${ports[@]}"; do
  name=$(echo "$port" | cut -d':' -f3)
  prot=$(echo "$port" | cut -d':' -f2)
  port=$(echo "$port" | cut -d':' -f1)
  if [[ -z "$(jq ".rules | map(select(.direction==\"in\" and .port==\"$port\")) | .[]" < /tmp/firewall.json)" ]]; then
    hcloud firewall add-rule cluster --description="$name" --protocol="$prot" --port="$port" --direction=in --source-ips=0.0.0.0/0 --source-ips=::/0
  fi
done

echo firewall configured

# Now we're finally ready to bootstrap the nodes proper.
export loadbalancer_ip=$(jq -r .public_net.ipv4.ip < /tmp/lb.json)

for name in cluster{1..3}; do
  if ! hcloud server describe $name -o json >/tmp/server-$name.json 2>/dev/null; then
    hcloud server create \
      --name $name \
      --type $server_type \
      --placement-group cluster \
      --ssh-key $ssh_key \
      --image $image \
      --location $location \
      --label cluster= \
      --network cluster
    hcloud server describe $name -o json >/tmp/server-$name.json
  fi

  # Nuke any existing host keys for this node (Hetzner Cloud recycles IPs as a "feature", annoying 99% of the time)
  # and then wait for it to accept SSH connections.
  server_ip=$(jq -r .public_net.ipv4.ip < /tmp/server-$name.json)
  ssh-keygen -R "$server_ip"
  until ssh -o StrictHostKeyChecking=accept-new root@"$server_ip" echo hi mom >/dev/null 2>&1; do sleep 1; done

  # Jump into this new node and install Docker + kube components on it.
  ssh -T root@"$server_ip" kube_version=$kube_version bash <<-"INIT"
    set -ueo pipefail
    export DEBIAN_FRONTEND=noninteractive

    if ! command -v etcdctl >/dev/null 2>&1; then
      apt-get update
      apt-get install -y etcd-client
    fi

    if [[ ! -x /usr/local/bin/etcdctl ]]; then
      cat > /usr/local/bin/etcdctl <<< '#!/bin/bash'
      cat >> /usr/local/bin/etcdctl <<< 'export ETCDCTL_API=3; exec /usr/bin/etcdctl --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/peer.crt --key /etc/kubernetes/pki/etcd/peer.key "$@"'
      chmod +x /usr/local/bin/etcdctl
    fi

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
    cat > /etc/kubernetes/audit-policy.yaml <<-HERE
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
HERE
INIT
  echo node $name configured
done

# We now have 3 nodes up and running. Maybe this script is running later and there's already a cluster setup on at
# least one of the nodes, though. Let's quickly check.
cluster_master=""
for name in cluster{1..3}; do
  server_ip=$(jq -r .public_net.ipv4.ip < /tmp/server-$name.json)
  if [[ "$(ssh root@"$server_ip" '[[ -f /etc/kubernetes/admin.conf ]] && echo "yes" || echo "no"')" == "yes" ]]; then
    cluster_master=$name
  fi
done

if [[ -z "$cluster_master" ]]; then
  # No cluster yet. Run kubeadm init on the first node to create one.
  server_ip=$(jq -r .public_net.ipv4.ip < /tmp/server-cluster1.json)
  private_ip=$(jq -r '.private_net[0].ip' < /tmp/server-cluster1.json)
  ./_generate-kubeadm-config.sh > /tmp/kubeadm
  cat >> /tmp/kubeadm <<KUBEADM
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $private_ip
nodeRegistration:
  kubeletExtraArgs:
    node-ip: $private_ip
    cloud-provider: external
skipPhases:
- add/kube-proxy
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
metricsBindAddress: 0.0.0.0:10249
KUBEADM

  ssh root@"$server_ip" "kubeadm init --config /dev/stdin" </tmp/kubeadm
  cluster_master=cluster1
fi

# A cluster now exists, make sure it's added to the local kubeconfig.
if ! kubectl config get-contexts | grep personal-admin@personal >/dev/null 2>&1; then
  mkdir -p ~/.kube
  hcloud server ssh $cluster_master 'cat /etc/kubernetes/admin.conf | sed -e s/kubernetes-admin/personal-admin/' > ~/.kube/personal.conf
  [[ -f $HOME/.kube/config ]] && mv "$HOME"/.kube/config{,.bak}
  KUBECONFIG=$HOME/.kube/config.bak:$HOME/.kube/personal.conf kubectl config view --raw > "$HOME"/.kube/config
  rm ~/.kube/personal.conf
fi

echo cluster initialized

# Now it's time to join the remaining nodes into the cluster.
# We'll be needing a hash of the root Kubernetes CA cert for `kubeadm join` later.
cluster_master_ip=$(jq -r .public_net.ipv4.ip < /tmp/server-$cluster_master.json)
discovery_token_hash=sha256:$(ssh root@"$cluster_master_ip" -T "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'")

# We'll also need a bootstrap token.
join_token=$(ssh root@"$cluster_master_ip" -T <<"TOKEN"
  token=$(kubeadm token list | grep authentication | cut -d' ' -f1 | tail -n1)
  if [[ -z "$token" ]]; then
    token=$(kubeadm token generate)
  fi
  echo $token
TOKEN
)

cert_key=$(ssh root@"$cluster_master_ip" -T <<"CERTS"
  set -ueo pipefail
  cert_key=$(kubeadm certs certificate-key)
  kubeadm init phase upload-certs --upload-certs --certificate-key $cert_key >/dev/null
  echo $cert_key
CERTS
)

for name in cluster{1..3}; do
  private_ip=$(jq -r '.private_net[0].ip' < /tmp/server-$name.json)
  public_ip=$(jq -r '.public_net.ipv4.ip' < /tmp/server-$name.json)
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

  ssh root@"$public_ip" "if [[ ! -f /etc/kubernetes/kubelet.conf ]]; then kubeadm join --config /dev/stdin; fi" < /tmp/kubeadm
done

# Done with SSH stuff, we can close off SSH access now.
hcloud firewall delete-rule cluster --direction=in --protocol=tcp --source-ips=0.0.0.0/0 --source-ips=::/0 --port 22 --description=TempSSH

# On the home stretch now! Time to get some baseline cluster stuff setup.

kube_ctx="--context=personal-admin@personal"
kubectl="kubectl $kube_ctx"

# Bootstrap Cilium
if ! helm --kube-context=personal-admin@personal -n kube-system status cilium >/dev/null 2>&1; then
  helm repo add cilium https://helm.cilium.io/
  helm repo update cilium
  helm --kube-context=personal-admin@personal -n kube-system cilium cilium/cilium --version=v1.11.1 --values core/cilium/values.yaml
fi

# We'll stuff the HCLOUD_TOKEN we've been using all this time into the cluster as well.
# The cluster autoscaler, hcloud CSI driver and CCM all need it.
$kubectl -n kube-system create secret generic hcloud --from-literal=HCLOUD_TOKEN=$HCLOUD_TOKEN -o yaml --dry-run=client \
  | $kubectl apply -f-

# The hash of the Kubernetes CA will be useful for cluster-autoscaler later, when bringing up new workers.
$kubectl -n kube-system create secret generic discovery-token-hash --from-literal=hash="$discovery_token_hash" -o yaml --dry-run=client \
  | $kubectl apply -f-

# Lots of secrets in this repo, they're encrypted with Age, using Mozilla SOPS. All secrets are encrypted against
# a cluster keypair. The private part of this keypair is in turn encrypted to my personal SSH keypair.
$kubectl -n kube-system create secret generic age-key --from-file=age-key.txt=<(age -d -i ~/.ssh/id_ed25519 < age-key.txt) -o yaml --dry-run=client \
  | $kubectl apply -f-

echo cluster secrets configured

if ! helm --kube-context=personal-admin@personal -n flux-system status flux >/dev/null 2>&1; then
  helm repo add fluxcd-community https://fluxcd-community.github.io/helm-charts
  helm repo update fluxcd-community
  helm --kube-context=personal-admin@personal -n flux-system flux fluxcd-community/flux2 --values core/flux/values.yaml --create-namespace
fi

echo flux configured

# Done. The fruits of our labor:
$kubectl get nodes

echo "all done"
