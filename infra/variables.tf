# =====================================================================
# Cost-optimised defaults for a personal / dev subscription.
# Anything marked [COST] is a deliberate saving; raise it for real use.
# =====================================================================

variable "subscription_id" {
  type        = string
  description = "Target Azure subscription ID."
}

variable "workload" {
  type        = string
  description = "Short workload name used in resource names (lowercase letters/digits, <= 8 chars)."
  default     = "aiops"
}

variable "environment" {
  type        = string
  description = "Environment short name (dev, test, prod)."
  default     = "dev"
}

variable "location" {
  type        = string
  description = "Region for AKS and supporting resources."
  default     = "centralindia"
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

# ---------------- Budget guard ----------------
variable "monthly_budget_amount" {
  type        = number
  description = "[COST] Monthly budget (in the subscription's billing currency) for the resource group. 0 disables the budget."
  default     = 50
}

variable "budget_contact_emails" {
  type        = list(string)
  description = "Emails notified at 80% actual and 100% forecasted spend. Required when monthly_budget_amount > 0."
  default     = []
}

# ---------------- Networking ----------------
variable "vnet_address_space" {
  type    = list(string)
  default = ["10.10.0.0/16"]
}

variable "aks_subnet_prefix" {
  type    = string
  default = "10.10.0.0/22"
}

variable "private_endpoint_subnet_prefix" {
  type    = string
  default = "10.10.8.0/27"
}

# Azure CNI Overlay ranges - must not overlap the VNet or any peered/on-prem network.
variable "pod_cidr" {
  type    = string
  default = "192.168.0.0/16"
}

variable "service_cidr" {
  type    = string
  default = "10.200.0.0/16"
}

variable "dns_service_ip" {
  type    = string
  default = "10.200.0.10"
}

# ---------------- AKS ----------------
variable "kubernetes_version" {
  type        = string
  description = "AKS version. Null = region default. Check `az aks get-versions` for supported versions."
  default     = null
}

variable "aks_sku_tier" {
  type        = string
  description = "[COST] Free = no control-plane charge and no uptime SLA. Standard/Premium for production."
  default     = "Free"
}

variable "private_cluster_enabled" {
  type    = bool
  default = false
}

variable "api_server_authorized_ip_ranges" {
  type        = list(string)
  description = "CIDRs allowed to reach the public API server. Ignored for private clusters. Strongly recommended: add your own public IP/32."
  default     = []
}

variable "aks_admin_group_object_ids" {
  type        = list(string)
  description = "Entra ID group object IDs granted AKS RBAC Cluster Admin."
}

variable "availability_zones" {
  type        = list(string)
  description = "[COST] Empty = no zone spread (avoids cross-zone traffic and extra nodes). Use [\"1\",\"2\",\"3\"] for production."
  default     = []
}

variable "system_pool_only_critical_addons" {
  type        = bool
  description = "[COST] false lets workloads (kagent) share the system pool so no second pool is needed."
  default     = false
}

variable "system_pool_vm_size" {
  type        = string
  description = "[COST] Burstable 2 vCPU / 8 GiB. Check availability in your region (`az vm list-skus`)."
  default     = "Standard_B2ms"
}

variable "system_pool_min_count" {
  type        = number
  description = "[COST] Autoscaler floor of 1 node."
  default     = 1
}

variable "system_pool_max_count" {
  type        = number
  description = "[COST] Autoscaler ceiling - also your worst-case compute bill."
  default     = 2
}

variable "create_user_pool" {
  type        = bool
  description = "[COST] false = single node pool only. Set true to add a separate user pool."
  default     = false
}

variable "user_pool_vm_size" {
  type    = string
  default = "Standard_B2ms"
}

variable "user_pool_min_count" {
  type    = number
  default = 1
}

variable "user_pool_max_count" {
  type    = number
  default = 2
}

# ---------------- Monitoring ----------------
variable "enable_container_insights" {
  type        = bool
  description = "[COST] Container Insights ingests a lot of log data and is usually the biggest hidden cost. Off by default."
  default     = false
}

variable "enable_aks_diagnostics" {
  type        = bool
  description = "[COST] Send kube-audit-admin/guard/autoscaler logs to Log Analytics. Turn on when agents get write access."
  default     = false
}

variable "log_analytics_daily_quota_gb" {
  type        = number
  description = "[COST] Hard daily ingestion cap for the workspace. -1 = unlimited."
  default     = 0.5
}

# ---------------- ACR / Key Vault ----------------
variable "acr_sku" {
  type        = string
  description = "[COST] Basic is the cheapest tier (no private endpoints/geo-replication; use Premium for those)."
  default     = "Basic"
}

variable "key_vault_public_access_enabled" {
  type    = bool
  default = true
}

# ---------------- Azure OpenAI ----------------
variable "openai_location" {
  type        = string
  description = "Region for the Azure OpenAI account (model availability varies by region)."
  default     = "swedencentral"
}

variable "openai_deployment_name" {
  type    = string
  default = "kagent-chat"
}

variable "openai_model_name" {
  type        = string
  description = "[COST] Small model, billed per token. Verify availability/quota in your region."
  default     = "gpt-4o-mini"
}

variable "openai_model_version" {
  type        = string
  description = "Model version. Verify with `az cognitiveservices model list`."
  default     = "2024-07-18"
}

variable "openai_sku_name" {
  type        = string
  description = "Pay-as-you-go deployment type (no provisioned-throughput commitment)."
  default     = "GlobalStandard"
}

variable "openai_capacity" {
  type        = number
  description = "[COST] Rate limit in thousands of tokens/min. It is a cap, not a charge - you pay only for tokens used - so a low value also guards against runaway agent loops."
  default     = 30
}

variable "openai_local_auth_enabled" {
  type        = bool
  description = "Allow API-key auth. Set false to force Entra ID only (needs kagent support)."
  default     = true
}

variable "openai_public_network_access_enabled" {
  type    = bool
  default = true
}

# ---------------- kagent workload identity ----------------
variable "kagent_namespace" {
  type    = string
  default = "kagent"
}

variable "kagent_service_account" {
  type        = string
  description = "ServiceAccount the federated credential trusts. Confirm the name the kagent chart creates."
  default     = "kagent-controller"
}
