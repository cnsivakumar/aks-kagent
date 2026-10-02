terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  prefix = "${var.workload}-${var.environment}"
  tags = merge({
    workload    = var.workload
    environment = var.environment
    managed_by  = "terraform"
  }, var.extra_tags)

  acr_name = "acr${var.workload}${var.environment}${random_string.suffix.result}"
  kv_name  = substr("kv-${local.prefix}-${random_string.suffix.result}", 0, 24)
  oai_name = "oai-${local.prefix}-${random_string.suffix.result}"
}

# ======================= Resource group =======================
resource "azurerm_resource_group" "this" {
  name     = "rg-${local.prefix}-${var.location}"
  location = var.location
  tags     = local.tags
}

# ======================= Networking =======================
resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = var.vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_prefix]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.private_endpoint_subnet_prefix]
}

# ======================= Observability =======================
resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = var.log_analytics_daily_quota_gb
  tags                = local.tags
}

# ======================= Container Registry =======================
resource "azurerm_container_registry" "this" {
  name                = local.acr_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = var.acr_sku
  admin_enabled       = false
  tags                = local.tags
}

# ======================= Key Vault =======================
resource "azurerm_key_vault" "this" {
  name                          = local.kv_name
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7
  public_network_access_enabled = var.key_vault_public_access_enabled
  tags                          = local.tags
}

resource "azurerm_role_assignment" "kv_deployer_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ======================= AKS =======================
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${local.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = "aks-${local.prefix}"
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.aks_sku_tier

  private_cluster_enabled   = var.private_cluster_enabled
  local_account_disabled    = true
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  azure_policy_enabled      = true
  image_cleaner_enabled     = true

  image_cleaner_interval_hours = 48
  automatic_upgrade_channel    = "patch"
  node_os_upgrade_channel      = "NodeImage"

  identity {
    type = "SystemAssigned"
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    admin_group_object_ids = var.aks_admin_group_object_ids
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_pool_vm_size
    vnet_subnet_id               = azurerm_subnet.aks.id
    zones                        = var.availability_zones
    auto_scaling_enabled         = true
    min_count                    = var.system_pool_min_count
    max_count                    = var.system_pool_max_count
    only_critical_addons_enabled = var.system_pool_only_critical_addons
    temporary_name_for_rotation  = "systmp"

    upgrade_settings {
      max_surge = "33%"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  dynamic "api_server_access_profile" {
    for_each = (!var.private_cluster_enabled && length(var.api_server_authorized_ip_ranges) > 0) ? [1] : []
    content {
      authorized_ip_ranges = var.api_server_authorized_ip_ranges
    }
  }

  dynamic "oms_agent" {
    for_each = var.enable_container_insights ? [1] : []
    content {
      log_analytics_workspace_id      = azurerm_log_analytics_workspace.this.id
      msi_auth_for_monitoring_enabled = true
    }
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  count                 = var.create_user_pool ? 1 : 0
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"
  vm_size               = var.user_pool_vm_size
  vnet_subnet_id        = azurerm_subnet.aks.id
  zones                 = var.availability_zones
  auto_scaling_enabled  = true
  min_count             = var.user_pool_min_count
  max_count             = var.user_pool_max_count
  tags                  = local.tags

  upgrade_settings {
    max_surge = "33%"
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}

# Control-plane identity needs rights on the BYO subnet (load balancers etc.)
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = azurerm_subnet.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "aks_cluster_admins" {
  for_each             = toset(var.aks_admin_group_object_ids)
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}

# Control-plane audit logs - useful for tracing what agents did in the cluster.
resource "azurerm_monitor_diagnostic_setting" "aks" {
  count                      = var.enable_aks_diagnostics ? 1 : 0
  name                       = "diag-aks"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "kube-audit-admin"
  }
  enabled_log {
    category = "guard"
  }
  enabled_log {
    category = "cluster-autoscaler"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

# ======================= Azure OpenAI =======================
resource "azurerm_cognitive_account" "openai" {
  name                          = local.oai_name
  location                      = var.openai_location
  resource_group_name           = azurerm_resource_group.this.name
  kind                          = "OpenAI"
  sku_name                      = "S0"
  custom_subdomain_name         = local.oai_name
  local_auth_enabled            = var.openai_local_auth_enabled
  public_network_access_enabled = var.openai_public_network_access_enabled
  tags                          = local.tags
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.openai_deployment_name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.openai_model_name
    version = var.openai_model_version
  }

  sku {
    name     = var.openai_sku_name
    capacity = var.openai_capacity
  }
}

# ======================= kagent workload identity =======================
resource "azurerm_user_assigned_identity" "kagent" {
  name                = "id-kagent-${local.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "kagent" {
  name                = "kagent-aks"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.kagent.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:${var.kagent_namespace}:${var.kagent_service_account}"
}

resource "azurerm_role_assignment" "kagent_openai_user" {
  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.kagent.principal_id
}

resource "azurerm_role_assignment" "kagent_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.kagent.principal_id
}

# ======================= Budget guard =======================
resource "azurerm_consumption_budget_resource_group" "this" {
  count             = var.monthly_budget_amount > 0 ? 1 : 0
  name              = "budget-${local.prefix}"
  resource_group_id = azurerm_resource_group.this.id
  amount            = var.monthly_budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00'Z'", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_contact_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.budget_contact_emails
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}
