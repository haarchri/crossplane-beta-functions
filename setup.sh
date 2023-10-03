#!/bin/bash
set -e

kind create cluster --name=xp-beta-functions --config=kind-config.yaml
kubectx kind-xp-beta-functions

kubectl create namespace crossplane-system
kubectl apply -f init/pv.yaml

helm install crossplane --namespace crossplane-system --create-namespace https://charts.crossplane.io/master/crossplane-1.14.0-rc.0.392.g53f713cd.tgz --set args='{--debug}'

# setup local-storage and patch crossplane container
kubectl -n crossplane-system patch deployment/crossplane --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/1","value":{"image":"alpine","name":"dev","command":["sleep","infinity"],"volumeMounts":[{"mountPath":"/tmp/cache","name":"package-cache"}]}},{"op":"add","path":"/spec/template/metadata/labels/patched","value":"true"}]'
kubectl -n crossplane-system wait deploy crossplane --for condition=Available --timeout=60s
kubectl -n crossplane-system wait pods -l app=crossplane,patched=true --for condition=Ready --timeout=60s

# need to use crank from https://github.com/crossplane/crossplane/pull/4694
./crank xpkg build --ignore="init/*.yaml,kind-config.yaml,.up/examples/spoke-cluster.yaml,.up/examples/xeks-spoke-cluster.yaml,.up/examples/xnetwork-spoke-cluster.yaml,.up/examples/xservices-spoke-cluster.yaml" --output=test.xpkg
# up xpkg build --ignore="init/*.yaml,kind-config.yaml" --output=test.xpkg
up xpkg xp-extract --from-xpkg test.xpkg -o ./test.gz

kubectl -n crossplane-system cp ./test.gz -c dev $(kubectl -n crossplane-system get pod -l app=crossplane,patched=true -o jsonpath="{.items[0].metadata.name}"):/tmp/cache
kubectl apply -f init/xpkg.yaml

echo "Creating aws cloud credential secret..."
kubectl -n crossplane-system create secret generic aws-creds --from-literal=credentials="${UPTEST_AWS_CLOUD_CREDENTIALS}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "Creating azure cloud credential secret..."
kubectl -n crossplane-system create secret generic azure-creds --from-literal=credentials="${UPTEST_AZURE_CLOUD_CREDENTIALS}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "Creating gcp cloud credential secret..."
kubectl -n crossplane-system create secret generic gcp-creds --from-literal=credentials="${UPTEST_GCP_CLOUD_CREDENTIALS}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "Waiting for all pods to come online..."
kubectl -n crossplane-system wait --for=condition=Available deployment --all --timeout=10m

echo "Creating a default aws providerconfig..."
cat <<EOF | kubectl apply -f -
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    secretRef:
      key: credentials
      name: aws-creds
      namespace: crossplane-system
    source: Secret
EOF

# echo "Creating a default azure providerconfig..."
# cat <<EOF | kubectl apply -f -
# apiVersion: azure.upbound.io/v1beta1
# kind: ProviderConfig
# metadata:
#   name: default
# spec:
#   credentials:
#     secretRef:
#       key: credentials
#       name: azure-creds
#       namespace: upbound-system
#     source: Secret
# EOF

# echo "Creating a default gcp providerconfig..."
# cat <<EOF | kubectl apply -f -
# apiVersion: gcp.upbound.io/v1beta1
# kind: ProviderConfig
# metadata:
#   name: default
# spec:
#   credentials:
#     secretRef:
#       key: credentials
#       name: gcp-creds
#       namespace: upbound-system
#     source: Secret
#   projectID: ${UPTEST_GCP_PROJECT}
# EOF
