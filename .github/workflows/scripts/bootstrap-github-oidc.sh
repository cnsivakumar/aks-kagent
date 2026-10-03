#!/usr/bin/env bash
# One-time setup so GitHub Actions can run Terraform against your subscription
# without any stored secrets:
#   1. Remote-state storage account + container
#   2. Entra app registration with GitHub OIDC federated credentials
#   3. Role assignments for that identity
#   4. (optional) writes the GitHub repository variables the workflows use
#
# Usage:
#   GITHUB_REPO=<org>/<repo> ./scripts/bootstrap-github-oidc.sh
# Optional env: LOCATION, STATE_RG, STATE_SA, STATE_CONTAINER, GH_ENVIRONMENT, SET_GH_VARS=true
#
# Run while logged in with `az login` as an account that can create app registrations and
# role assignments (e.g. Owner on the subscription).
set -euo pipefail

: "${GITHUB_REPO:?set GITHUB_REPO=<org>/<repo>}"
LOCATION="${LOCATION:-centralindia}"
STATE_RG="${STATE_RG:-rg-tfstate}"
STATE_SA="${STATE_SA:-sttfstate$(openssl rand -hex 4)}"   # 3-24 chars, lowercase letters/digits, globally unique
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"
GH_ENVIRONMENT="${GH_ENVIRONMENT:-production}"
APP_NAME="${APP_NAME:-gh-${GITHUB_REPO//\//-}-terraform}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

echo ">> State storage: $STATE_RG / $STATE_SA / $STATE_CONTAINER"
az group create -n "$STATE_RG" -l "$LOCATION" -o none
az storage account create -n "$STATE_SA" -g "$STATE_RG" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
  --allow-blob-public-access false -o none
az storage account blob-service-properties update \
  --account-name "$STATE_SA" -g "$STATE_RG" --enable-versioning true -o none
az storage container create --account-name "$STATE_SA" -n "$STATE_CONTAINER" -o none
SA_ID="$(az storage account show -n "$STATE_SA" -g "$STATE_RG" --query id -o tsv)"

echo ">> App registration: $APP_NAME"
APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
az ad sp create --id "$APP_ID" -o none

create_fic() {  # name subject
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"$1\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$2\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none
}
create_fic "github-main"        "repo:${GITHUB_REPO}:ref:refs/heads/main"
create_fic "github-pr"          "repo:${GITHUB_REPO}:pull_request"
create_fic "github-environment" "repo:${GITHUB_REPO}:environment:${GH_ENVIRONMENT}"

echo ">> Role assignments (allow a minute for the new service principal to propagate)"
sleep 30
SCOPE="/subscriptions/${SUBSCRIPTION_ID}"
az role assignment create --assignee "$APP_ID" --role "Contributor" --scope "$SCOPE" -o none
# Terraform creates role assignments (AcrPull, Key Vault roles, ...), which needs this.
# It is powerful: consider restricting it with an ABAC condition limited to those roles.
az role assignment create --assignee "$APP_ID" --role "User Access Administrator" --scope "$SCOPE" -o none
az role assignment create --assignee "$APP_ID" --role "Storage Blob Data Contributor" --scope "$SA_ID" -o none

cat <<OUT

Set these GitHub repository VARIABLES (Settings > Secrets and variables > Actions > Variables):
  AZURE_CLIENT_ID            = $APP_ID
  AZURE_TENANT_ID            = $TENANT_ID
  AZURE_SUBSCRIPTION_ID      = $SUBSCRIPTION_ID
  TFSTATE_RESOURCE_GROUP     = $STATE_RG
  TFSTATE_STORAGE_ACCOUNT    = $STATE_SA
  TFSTATE_CONTAINER          = $STATE_CONTAINER
Also set (not created here):
  AKS_ADMIN_GROUP_OBJECT_IDS = ["<entra-group-object-id>"]
  BUDGET_CONTACT_EMAILS      = ["you@example.com"]
  AKS_RESOURCE_GROUP / AKS_NAME / AKS_AUTO_STOP   (for the start/stop workflow, after first apply)
And create a GitHub environment named "$GH_ENVIRONMENT" with required reviewers.
OUT

if [[ "${SET_GH_VARS:-false}" == "true" ]] && command -v gh >/dev/null; then
  echo ">> Setting variables with gh"
  gh variable set AZURE_CLIENT_ID         --repo "$GITHUB_REPO" --body "$APP_ID"
  gh variable set AZURE_TENANT_ID         --repo "$GITHUB_REPO" --body "$TENANT_ID"
  gh variable set AZURE_SUBSCRIPTION_ID   --repo "$GITHUB_REPO" --body "$SUBSCRIPTION_ID"
  gh variable set TFSTATE_RESOURCE_GROUP  --repo "$GITHUB_REPO" --body "$STATE_RG"
  gh variable set TFSTATE_STORAGE_ACCOUNT --repo "$GITHUB_REPO" --body "$STATE_SA"
  gh variable set TFSTATE_CONTAINER       --repo "$GITHUB_REPO" --body "$STATE_CONTAINER"
fi
