#!/bin/bash
set -uexo pipefail

tag=$(cat Dockerfile update-cloud-init.sh | sha256sum | cut -d' ' -f1)
image=samcday/cloud-init-generator:$tag

docker build -t "$image" .
docker push "$image"
