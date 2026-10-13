output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "acr_name" {
  value = azurerm_container_registry.acr.name
}

output "argocd_public_ip" {
  value = azurerm_public_ip.argocd.ip_address
}

output "key_vault_name" {
  value = azurerm_key_vault.keyvault.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks-cluster.name
}

output "aks_agent_node_count" {
  value = local.node_counts[var.environment]
}

output "aks_vm_size" {
  value = local.vm_sizes[var.environment]
}
