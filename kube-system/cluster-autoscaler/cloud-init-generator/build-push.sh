#!/bin/bash
set -uexo pipefail

tag=$(sha256sum Dockerfile | cut -d' ' -f1)
image=samcday/cloud-init-generator:$tag

docker build -t "$image" .
docker push "$image"
