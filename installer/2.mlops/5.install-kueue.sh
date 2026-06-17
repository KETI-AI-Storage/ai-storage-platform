helm install kueue oci://registry.k8s.io/kueue/charts/kueue \
  --version=0.14.4 \
  --namespace  kueue-system \
  --create-namespace \
  --wait --timeout 300s
