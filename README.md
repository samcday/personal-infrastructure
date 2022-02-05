# personal-infrastructure

The place where I run all my stuff. It's a Kubernetes cluster running on Hetzner Cloud.

## `bootstrap.sh`

An extremely sophisticated Web Scale task runner (Bash) is used to:

 * Bring up the Hetzner Cloud resources (servers, load balancer, firewall, private network)
 * Install Docker + kubeadm on each machine
 * Initialize a cluster with `kubeadm init` if one does not yet exist
 * Connect all servers to the cluster with `kubeadm join`
 * Install [Cilium](https://cilium.io/) and [Flux2](https://fluxcd.io)

From here, Kubernetes + Flux takes over and everything becomes a nail.

## Flux bootstrapping

Flux manages all resources in the created cluster. It also manages itself. This will probably prove to be a bad idea.

Bootstrapping from scratch should be simple, though:

```sh
helm install -n flux-system flux fluxcd-community/flux2 --create-namespace
kustomize --load-restrictor LoadRestrictionsNone build core/flux | kubectl apply -f-
```
