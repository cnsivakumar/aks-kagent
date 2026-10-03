#!/usr/bin/env bash
# Installs kagent on the AKS cluster created by this Terraform project.
# Prerequisites: `terraform apply` done, and `az aks get-credentials` + kubelogin configured.
# Run from this folder:  ./install.sh
set -euo pipefail

KAGENT_VERSION="${KAGENT_VERSION:-0.9.9}"   # pin; check for newer releases first
NAMESPACE="${NAMESPACE:-kagent}"
TF_DIR="${TF_DIR:-..}"

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

RG="$(tf_out resource_group_name)"
OAI_NAME="$(tf_out openai_account_name)"
OAI_ENDPOINT="$(tf_out openai_endpoint)"
OAI_DEPLOYMENT="$(tf_out openai_deployment_name)"

# Fetch the API key at install time; it is never written to a file.
AZURE_OPENAI_API_KEY="$(az cognitiveservices account keys list \
  -g "$RG" -n "$OAI_NAME" --query key1 -o tsv)"

echo ">> Installing kagent CRDs ($KAGENT_VERSION)"
helm upgrade --install kagent-crds \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --version "$KAGENT_VERSION" \
  --namespace "$NAMESPACE" --create-namespace --wait

echo ">> Installing kagent ($KAGENT_VERSION)"
helm upgrade --install kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --version "$KAGENT_VERSION" \
  --namespace "$NAMESPACE" \
  --values values.yaml \
  --set providers.azureOpenAI.apiKey="$AZURE_OPENAI_API_KEY" \
  --set providers.azureOpenAI.config.azureEndpoint="$OAI_ENDPOINT" \
  --set providers.azureOpenAI.config.azureDeployment="$OAI_DEPLOYMENT" \
  --wait --timeout 10m

echo ">> Applying custom agent"
kubectl apply -f aks-triage-agent.yaml

echo ">> Done. Open the UI with:"
echo "   kubectl port-forward -n $NAMESPACE svc/kagent-ui 8080:8080"
