#!/bin/bash

required_tools=(hcloud jq kubectl cilium flux helm)
for command in "${required_tools[@]}"; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "ERROR: $command not found"
    exit 1
  fi
done

export server_type=cx21
export image=ubuntu-20.04
export location=fsn1
export ssh_key=mine
export loadbalancer_type=lb11
export network_cidr=10.96.0.0/14
export subnet_cidr=10.96.0.0/16
export kube_version=1.22.6

[[ -f .env ]] && source .env

if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
  echo "HCLOUD_TOKEN not set"
  exit 1
fi
export HCLOUD_TOKEN
