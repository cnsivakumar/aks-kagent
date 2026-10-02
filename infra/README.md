# AKS + Azure OpenAI foundation for kagent (Terraform)

Terraform that provisions a **low-cost Azure Kubernetes Service (AKS) cluster** and the supporting
Azure resources needed to run [kagent](https://kagent.dev) (Kubernetes-native AI agents) on it,
using Azure OpenAI as the LLM backend and Entra Workload Identity for secretless access.

> **Status:** the code has not been through `terraform validate`/`plan` against a live subscription.
> Run both before applying, and review the "Verify before first apply" section.

The defaults target a **personal or dev subscription** where cost matters more than resilience.
For production, see [Production hardening](#production-hardening).

## What gets deployed

| Resource | Notes |
|---|---|
| Resource group, VNet | One AKS subnet and one (currently unused) private-endpoint subnet |
| AKS cluster | Free tier, Azure CNI Overlay + Cilium (data plane and network policy), Entra ID auth with Azure RBAC, local accounts disabled, OIDC issuer + workload identity, Azure Policy add-on, Key Vault CSI driver, image cleaner, automatic `patch` upgrades, `NodeImage` OS upgrades |
| Node pools | One autoscaling system pool (shared with workloads by default); optional separate user pool |
| Azure Container Registry | Basic SKU, admin user disabled, `AcrPull` granted to the kubelet identity |
| Key Vault | RBAC authorization, purge protection on |
| Azure OpenAI | Account plus one model deployment (default `gpt-4o-mini`) |
| kagent identity | User-assigned managed identity with a federated credential for the kagent ServiceAccount; roles: *Cognitive Services OpenAI User* on the OpenAI account, *Key Vault Secrets User* on the vault |
| Log Analytics workspace | With a daily ingestion cap; Container Insights and AKS diagnostics are optional |
| Budget (optional) | Resource-group budget with email alerts at 80% actual / 100% forecast |

kagent itself is **not** installed by this Terraform. Install it with Helm or through your GitOps tooling (see below).

## Prerequisites

- Terraform >= 1.9, Azure CLI, `kubectl`, `kubelogin`, Helm
- An Azure subscription where you can create resources **and** role assignments (Owner, or Contributor plus User Access Administrator)
- Resource providers registered, for example: `Microsoft.ContainerService`, `Microsoft.CognitiveServices`, `Microsoft.KeyVault`, `Microsoft.OperationalInsights`, `Microsoft.Consumption`
- An Entra ID group whose members should administer the cluster (you need its object ID)
- Quota for your chosen VM size and Azure OpenAI model in the chosen regions

## Usage

```bash
az login
az account set --subscription <subscription-id>

cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: subscription_id, aks_admin_group_object_ids, budget_contact_emails

terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Connect to the cluster:

```bash
# or run the get_credentials_command output
az aks get-credentials -g <resource-group> -n <aks-name>
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes
```

> Local accounts are disabled. If `aks_admin_group_object_ids` is wrong or empty you will not be able to administer the cluster.

## Verify before first apply

1. **Model and version.** Defaults (`gpt-4o-mini`, `2024-07-18`, `GlobalStandard`) are placeholders. Confirm availability and quota in `openai_location` (`az cognitiveservices model list`) and adjust.
2. **VM size.** Default is `Standard_B2ms`; confirm it exists in your region (`az vm list-skus`).
3. **kagent ServiceAccount.** The federated credential trusts `system:serviceaccount:kagent:kagent-controller`. Check which ServiceAccount the kagent chart actually creates and set `kagent_service_account` accordingly.
4. **How kagent authenticates to Azure OpenAI.** Confirm in the kagent docs whether its Azure OpenAI provider supports Entra/workload identity. If it only supports API keys, store the key in Key Vault and mount it with the CSI driver.
5. **API server access.** The API server is public by default; set `api_server_authorized_ip_ranges` to your IP(s).

## Installing kagent

Per the kagent docs, install the CRDs chart first, then the application chart (check the docs for current versions and options, and pin a version):

```bash
helm install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace kagent --create-namespace

helm install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent
  # plus provider/model configuration for Azure OpenAI per the kagent docs,
  # using the openai_endpoint and openai_deployment_name outputs
```

To use workload identity, label and annotate the kagent ServiceAccount:

```yaml
metadata:
  labels:
    azure.workload.identity/use: "true"
  annotations:
    azure.workload.identity/client-id: "<kagent_identity_client_id output>"
```

Keep the kagent release in your GitOps repo (ArgoCD/Flux) rather than in this Terraform state.

## Cost controls

Variables tagged `[COST]` in `variables.tf` are deliberate savings:

| Variable | Default | Effect |
|---|---|---|
| `aks_sku_tier` | `Free` | No control-plane charge, no uptime SLA |
| `system_pool_vm_size` | `Standard_B2ms` | Small burstable node |
| `system_pool_min_count` / `max_count` | `1` / `2` | Autoscaler bounds; max is your worst-case compute |
| `create_user_pool` | `false` | Single node pool |
| `availability_zones` | `[]` | No zone spread |
| `enable_container_insights` | `false` | Avoids heavy log ingestion |
| `enable_aks_diagnostics` | `false` | No audit logs shipped (turn on before giving agents write access) |
| `log_analytics_daily_quota_gb` | `0.5` | Hard daily ingestion cap |
| `acr_sku` | `Basic` | Cheapest registry tier |
| `openai_model_name` / `openai_capacity` | `gpt-4o-mini` / `30` | Pay-per-token; capacity is a rate limit, not a charge |
| `monthly_budget_amount` | `50` | Budget alerts (set `budget_contact_emails`; `0` disables) |

Other tips:

- Stop compute when idle: `az aks stop -g <rg> -n <aks>` (disks, public IP and other resources still bill); resume with `az aks start`.
- The standard load balancer and its public IP bill hourly while the cluster exists.
- `terraform destroy` removes everything. Key Vault has purge protection, so its name stays reserved until the retention period ends (names include a random suffix, so re-deploying is unaffected).

## Key variables

| Variable | Required | Description |
|---|---|---|
| `subscription_id` | yes | Target subscription |
| `aks_admin_group_object_ids` | yes | Entra groups granted AKS RBAC Cluster Admin |
| `location` | no | AKS and supporting resources region (default `centralindia`) |
| `openai_location` | no | Azure OpenAI region (default `swedencentral`) |
| `workload`, `environment` | no | Naming (`<workload>-<environment>`) |
| `private_cluster_enabled` | no | Private API server |
| `api_server_authorized_ip_ranges` | no | Allowed CIDRs for a public API server |
| `kagent_namespace`, `kagent_service_account` | no | Subject of the federated credential |

See `variables.tf` for the full list and descriptions.

## Outputs

`resource_group_name`, `aks_name`, `get_credentials_command`, `acr_login_server`, `key_vault_uri`, `openai_endpoint`, `openai_deployment_name`, `kagent_identity_client_id`, `log_analytics_workspace_id`.

## Running agents safely

kagent's tools include mutating operations (for example patching or deleting resources and Helm upgrades), so treat agents as privileged workloads:

- Start with **read-only** agents (dedicated ServiceAccounts with narrow ClusterRoles) and add write permissions per action and namespace.
- Prefer **PR-based remediation** against your GitOps repo over direct changes to live state.
- Enable `enable_aks_diagnostics` so `kube-audit-admin` logs record what agents change.
- Throttle and de-duplicate whatever triggers agents (alert webhooks) to avoid alert storms driving LLM cost.

## Production hardening

This code is a starting point, not a production landing zone. Typical next steps:

- `aks_sku_tier = "Standard"` (or `Premium`), `availability_zones = ["1","2","3"]`, a dedicated user pool, larger nodes, higher autoscaler minimums
- `private_cluster_enabled = true`, private endpoints and private DNS for ACR (Premium SKU), Key Vault and Azure OpenAI, then disable their public access
- Managed Prometheus/Grafana and Azure Monitor alert rules; enable Container Insights and diagnostics
- Remote state (the `backend "azurerm"` block in `versions.tf` is commented out), CI/CD pipeline with plan review, and Azure Policy / Kyverno guardrails
- Consider migrating to Azure Verified Modules (AVM) for AKS, ACR and Key Vault

## File layout

| File | Purpose |
|---|---|
| `versions.tf` | Terraform/provider versions, provider config, commented backend |
| `variables.tf` | All inputs with cost-optimised defaults |
| `main.tf` | Resources |
| `outputs.tf` | Outputs |
| `terraform.tfvars.example` | Example inputs (copy to `terraform.tfvars`) |
