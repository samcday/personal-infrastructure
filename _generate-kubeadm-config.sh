#!/bin/bash
set -ueo pipefail
. _setup.sh

if [[ -z "${loadbalancer_ip:-}" ]]; then
    loadbalancer_ip=$(hcloud load-balancer describe cluster -o json | jq -r .public_net.ipv4.ip)
    export loadbalancer_ip
fi

envsubst < kubeadm-config.yaml
