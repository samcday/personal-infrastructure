#!/bin/ash
set -uexo pipefail

# This script runs hourly via a privleged CronJob in the cluster. It synthesizes a valid cloud-init script that
# cluster-autoscaler can use to scale up new workers. The bootstrap token is valid for 48 hours to ensure rotations
# don't interfere with a scale-up that happens at the same time.

# The HCLOUD_TOKEN token from the cluster is stuffed into the cloud-init because I couldn't be fucked facerolling
# a one-liner to determine the private IP via Bash. So I just do it via hcloud-cli.

# This script requires: jq, mikefarah/yq, kubeadm, kubectl

# discovery token and HCLOUD_TOKEN were stuffed into the cluster by bootstrap.sh
discovery_token_hash=$(kubectl -n kube-system get secret/discovery-token-hash -o json | jq -r .data.hash | base64 -d)

# The control-plane endpoint (load balancer) and kube version are set in the kubeadm configmap which, annoyingly, is in YAML. Hence this yq nonsense.
cp_endpoint=$(kubectl -n kube-system get cm/kubeadm-config -o json | jq -r .data.ClusterConfiguration | yq e '.controlPlaneEndpoint' -)
kube_version=$(kubectl -n kube-system get cm/kubeadm-config -o json | jq -r .data.ClusterConfiguration | yq e '.kubernetesVersion' -)
kube_version=${kube_version#v}

# kubeadm doesn't know how to deal with in-cluster config like kubectl does. Very annoying.
KUBECONFIG=kubeconfig kubectl config set-cluster cluster --server=https://kubernetes.default.svc --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
KUBECONFIG=kubeconfig kubectl config set-credentials user --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
KUBECONFIG=kubeconfig kubectl config set-context default --user=user --cluster=cluster
KUBECONFIG=kubeconfig kubectl config use-context default
token=$(KUBECONFIG=kubeconfig kubeadm token create --ttl 48h)

(base64 - > init) <<INIT
#!/bin/bash
set -ueo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https jq

private_ip=\$(curl http://169.254.169.254/hetzner/v1/metadata/private-networks | grep "ip: " | awk '{print $3}')

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg

echo "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io kubelet=$kube_version-00 kubeadm=$kube_version-00 kubectl=$kube_version-00
echo '{"exec-opts":["native.cgroupdriver=systemd"]}' > /etc/docker/daemon.json
systemctl restart docker.service

apt-mark hold kubelet kubeadm kubectl

cat > kubeadm.yml <<KUBEADM
apiVersion: kubeadm.k8s.io/v1beta2
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: $cp_endpoint
    token: $token
    caCertHashes: [$discovery_token_hash]
nodeRegistration:
  kubeletExtraArgs:
    node-ip: \$private_ip
    cloud-provider: external
KUBEADM
kubeadm join --config kubeadm.yml
INIT

kubectl -n kube-system create secret generic hcloud-cloud-init --from-file=HCLOUD_CLOUD_INIT=init -o yaml --dry-run=client | kubectl apply -f-

kubectl -n kube-system rollout restart deploy/cluster-autoscaler
