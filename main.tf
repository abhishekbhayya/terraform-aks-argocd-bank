resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

data "azuread_client_config" "current" {}

resource "random_string" "keyvault_suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_key_vault" "keyvault" {
  name                       = "${var.keyvault_name_prefix}${random_string.keyvault_suffix.result}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  sku_name                   = "standard"
  tenant_id                  = data.azuread_client_config.current.tenant_id
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
}

resource "azurerm_role_assignment" "terraform_keyvault" {
  scope                = azurerm_key_vault.keyvault.id
  principal_id         = data.azuread_client_config.current.object_id
  role_definition_name = "Key Vault Secrets Officer"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "subnet1" {
  name                 = "subnet-${var.environment}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_kubernetes_cluster" "aks-cluster" {
  name                = "${var.cluster_name_prefix}-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "${var.dns_prefix}-${var.environment}"

  default_node_pool {
    name                 = "systempool"
    vm_size              = local.vm_sizes[var.environment]
    node_count           = local.node_counts[var.environment]
    vnet_subnet_id       = azurerm_subnet.subnet1.id
    auto_scaling_enabled = false
    os_disk_size_gb      = 30
    type                 = "VirtualMachineScaleSets"
    zones                = var.availability_zones
  }

  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    service_cidr        = "10.10.0.0/16"
    dns_service_ip      = "10.10.0.10"
  }
}

resource "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.aks-cluster.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.acr.id
  skip_service_principal_aad_check = true
}

resource "azurerm_public_ip" "argocd" {
  name                = var.argocd_public_ip_name
  allocation_method   = "Static"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard"
}

resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks-cluster.identity[0].principal_id
}

resource "terraform_data" "import_acr_images" {
  triggers_replace = [
    azurerm_container_registry.acr.id,
    filesha256("${path.module}/scripts/import-bank-of-anthos-images.ps1")
  ]

  depends_on = [
    azurerm_container_registry.acr
  ]

  provisioner "local-exec" {
    interpreter = [
      "PowerShell",
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-Command"
    ]

    command = "& '${abspath(path.module)}/scripts/import-bank-of-anthos-images.ps1'"
  }
}

resource "terraform_data" "argocd_bootstrap" {
  triggers_replace = [
    filesha256("${path.module}/scripts/bootstrap-argocd.ps1")
  ]

  depends_on = [
    azurerm_kubernetes_cluster.aks-cluster,
    azurerm_container_registry.acr,
    azurerm_role_assignment.aks_acr_pull,
    azurerm_public_ip.argocd,
    azurerm_role_assignment.aks_network_contributor,
    terraform_data.import_acr_images
  ]

  provisioner "local-exec" {
    interpreter = [
      "PowerShell",
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-Command"
    ]

    command = "& '${abspath(path.module)}/scripts/bootstrap-argocd.ps1' -ResourceGroupName '${azurerm_resource_group.rg.name}' -ClusterName '${azurerm_kubernetes_cluster.aks-cluster.name}' -PublicIpName '${azurerm_public_ip.argocd.name}'"
  }
}

resource "azurerm_key_vault_secret" "kube" {
  name         = "kubeconfig"
  key_vault_id = azurerm_key_vault.keyvault.id
  value        = azurerm_kubernetes_cluster.aks-cluster.kube_config_raw

  depends_on = [
    azurerm_role_assignment.terraform_keyvault
  ]
}
