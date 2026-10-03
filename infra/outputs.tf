output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "get_credentials_command" {
  value = "az aks get-credentials -g ${azurerm_resource_group.this.name} -n ${azurerm_kubernetes_cluster.this.name} && kubelogin convert-kubeconfig -l azurecli"
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "openai_endpoint" {
  value = azurerm_cognitive_account.openai.endpoint
}

output "openai_deployment_name" {
  value = azurerm_cognitive_deployment.chat.name
}

output "kagent_identity_client_id" {
  description = "Annotate the kagent ServiceAccount with azure.workload.identity/client-id = this value."
  value       = azurerm_user_assigned_identity.kagent.client_id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "openai_account_name" {
  value = azurerm_cognitive_account.openai.name
}
