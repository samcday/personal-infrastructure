# personal-infrastructure

The place where I run all my stuff. It's a Kubernetes cluster running inside Hetzner Cloud servers.

## `bootstrap.sh`

An extremely sophisticated Web Scale task runner (Bash) is used to:

 * Bring up the Hetzner Cloud resources (servers + load balancer)
 * Install Docker + kubeadm on each machine
 * Initialize a cluster with `kubeadm init` if one does not yet exist
 * Connect all servers to the cluster with `kubeadm join`
 * Install [Cilium](https://cilium.io/) and [Flux2](https://fluxcd.io)

Everything else is handled in Kubernetes from then on.
