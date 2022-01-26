#!/bin/bash
set -ueo pipefail

. _setup.sh

kubectl patch -n kube-system --type merge --patch-file=/dev/stdin cm/kubeadm-config <<HERE
data:
  ClusterConfiguration: |
$(./_generate-kubeadm-config.sh | sed -e 's/^/    /')
HERE
