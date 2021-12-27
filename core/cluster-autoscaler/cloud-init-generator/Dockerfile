FROM busybox:stable-glibc

RUN wget -O /bin/yq https://github.com/mikefarah/yq/releases/download/v4.16.2/yq_linux_amd64 && chmod +x /bin/yq
RUN wget -O /bin/kubectl https://dl.k8s.io/release/v1.21.8/bin/linux/amd64/kubectl && chmod +x /bin/kubectl
RUN wget -O /bin/kubeadm https://storage.googleapis.com/kubernetes-release/release/v1.21.8/bin/linux/amd64/kubeadm && chmod +x /bin/kubeadm
RUN wget -O /bin/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 && chmod +x /bin/jq
