#-------------------------------
# Local Declarations
#-------------------------------
locals {
  resource_group_name = element(coalescelist(data.azurerm_resource_group.rgrp.*.name, azurerm_resource_group.rg.*.name, [""]), 0)
  location            = element(coalescelist(data.azurerm_resource_group.rgrp.*.location, azurerm_resource_group.rg.*.location, [""]), 0)
}

data "azurerm_client_config" "current" {}

#---------------------------------------------------------
# Resource Group Creation or selection - Default is "true"
#---------------------------------------------------------
data "azurerm_resource_group" "rgrp" {
  count = var.create_resource_group == false ? 1 : 0
  name  = var.resource_group_name
}

resource "azurerm_resource_group" "rg" {
  #ts:skip=AC_AZURE_0389 RSG lock should be skipped for now.
  count    = var.create_resource_group ? 1 : 0
  name     = lower(var.resource_group_name)
  location = var.location
  tags     = merge({ "ResourceName" = format("%s", var.resource_group_name) }, var.tags, )
}

#---------------------------------------------------------
# Log analytics workspace
#---------------------------------------------------------

resource "azurerm_resource_group" "rg_la" {
  #ts:skip=AC_AZURE_0389 RSG lock should be skipped for now.
  name     = lower(var.log_analytics_resource_group)
  location = var.location
  tags     = merge({ "ResourceName" = format("%s", var.log_analytics_resource_group) }, var.tags, )
}

resource "azurerm_log_analytics_workspace" "main" {
  #ts:skip=AC_AZURE_0389 RSG lock should be skipped for now.
  name                = var.log_analytics_workspace_name
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_la.name
  sku                 = var.log_analytics_workspace_sku
  retention_in_days   = var.log_retention_in_days
}

#---------------------------------------------------------
# SSH Key Creation or selection
#---------------------------------------------------------

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

#---------------------------------------------------------
# Read AD Group IDs
#---------------------------------------------------------

data "azuread_group" "main" {
  count        = length(var.rbac_aad_admin_group)
  display_name = var.rbac_aad_admin_group[count.index]
}

#---------------------------------------------------------
# Kubernetes Creation or selection
#---------------------------------------------------------
resource "azurerm_kubernetes_cluster" "main" {
  name                            = lower(var.name)
  location                        = local.location
  resource_group_name             = local.resource_group_name
  node_resource_group             = var.node_resource_group
  dns_prefix                      = var.prefix
  api_server_authorized_ip_ranges = var.authorized_ips
  sku_tier                        = var.sku_tier
  private_cluster_enabled         = var.private_cluster_enabled

  dynamic "default_node_pool" {
    for_each = var.enable_auto_scaling == true ? [] : ["default_node_pool_manually_scaled"]
    content {
      kubelet_config {
        container_log_max_line    = var.kubelet_log_max_line
        container_log_max_size_mb = var.kubelet_log_max_size_mb
      }
      name                         = var.node_pool_name
      node_count                   = var.node_count
      vm_size                      = var.default_vm_size
      os_disk_size_gb              = var.os_disk_size_gb
      os_disk_type                 = var.os_disk_type
      vnet_subnet_id               = var.vnet_subnet_id
      enable_auto_scaling          = var.enable_auto_scaling
      max_count                    = null
      min_count                    = null
      zones                        = var.availability_zones
      max_pods                     = var.max_default_pod_count
      type                         = "VirtualMachineScaleSets"
      only_critical_addons_enabled = var.system_only
    }
  }

  dynamic "default_node_pool" {
    for_each = var.enable_auto_scaling == true ? ["default_node_pool_auto_scaled"] : []
    content {
      kubelet_config {
        container_log_max_line    = var.kubelet_log_max_line
        container_log_max_size_mb = var.kubelet_log_max_size_mb
      }
      name                         = var.node_pool_name
      vm_size                      = var.default_vm_size
      os_disk_size_gb              = var.os_disk_size_gb
      os_disk_type                 = var.os_disk_type
      vnet_subnet_id               = var.vnet_subnet_id
      enable_auto_scaling          = var.enable_auto_scaling
      max_count                    = var.max_default_node_count
      min_count                    = var.min_default_node_count
      availability_zones           = var.availability_zones
      max_pods                     = var.max_default_pod_count
      type                         = "VirtualMachineScaleSets"
      only_critical_addons_enabled = var.system_only
    }
  }

  linux_profile {
    admin_username = "k8s"

    ssh_key {
      key_data = replace(var.public_ssh_key == "" ? tls_private_key.ssh.public_key_openssh : var.public_ssh_key, "\n", "")
    }
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  }

  http_application_routing_enabled = false

  dynamic "ingress_application_gateway" {
    for_each = (var.create_ingress && var.gateway_id != null) ? [true] : []
    content {
      gateway_id = var.gateway_id
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    #ts:skip=AC_AZURE_0158 This rule should be skipped for now.
    load_balancer_sku = length(var.availability_zones) == 0 && var.windows_node_pool_enabled == false ? var.load_balancer_sku : "standard"
    network_plugin    = var.windows_node_pool_enabled ? "azure" : var.network_plugin
    network_policy    = var.network_policy
  }

  role_based_access_control_enabled = var.enable_role_based_access_control

  dynamic "azure_active_directory_role_based_access_control" {
    for_each = var.enable_role_based_access_control && var.rbac_aad_managed ? ["rbac"] : []
    content {
      managed                = true
      admin_group_object_ids = length(var.rbac_aad_admin_group) == 0 ? var.rbac_aad_admin_group : data.azuread_group.main[*].id
      azure_rbac_enabled     = var.azure_rbac_enabled
    }
  }

  tags = merge({ "ResourceName" = lower(var.name) }, var.tags, )

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count, tags, linux_profile.0.ssh_key
    ]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "windows" {
  count                 = var.windows_node_pool_enabled ? 1 : 0
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  name                  = substr(var.windows_pool_name, 0, 6)
  node_count            = var.enable_windows_auto_scaling == false ? var.windows_node_count : null
  vm_size               = var.windows_vm_size
  os_disk_size_gb       = var.windows_os_disk_size_gb
  os_disk_type          = var.windows_os_disk_type
  vnet_subnet_id        = var.vnet_subnet_id
  enable_auto_scaling   = var.enable_windows_auto_scaling
  max_count             = var.enable_windows_auto_scaling ? var.max_default_windows_node_count : null
  min_count             = var.enable_windows_auto_scaling ? var.min_default_windows_node_count : null
  zones                 = var.availability_zones
  max_pods              = var.max_default_windows_pod_count
  node_taints           = ["os=windows:NoSchedule"]
  os_type               = "Windows"
}

resource "azurerm_kubernetes_cluster_node_pool" "system" {
  count                 = var.system_node_pool_enabled ? 1 : 0
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  name                  = "systempool"
  node_count            = var.enable_system_auto_scaling == false ? var.system_node_count : null
  vm_size               = var.system_vm_size
  os_disk_size_gb       = var.system_os_disk_size_gb
  os_disk_type          = var.system_os_disk_type
  vnet_subnet_id        = var.vnet_subnet_id
  enable_auto_scaling   = var.enable_system_auto_scaling
  max_count             = var.enable_system_auto_scaling ? var.max_default_system_node_count : null
  min_count             = var.enable_system_auto_scaling ? var.min_default_system_node_count : null
  zones                 = var.availability_zones
  max_pods              = var.max_default_system_pod_count
  node_taints           = ["CriticalAddonsOnly=true:NoSchedule"]
  mode                  = "System"
}

provider "azurerm" {
  features {
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    key_vault {
      purge_soft_delete_on_destroy               = true
      purge_soft_deleted_secrets_on_destroy      = true
      purge_soft_deleted_certificates_on_destroy = true
    }
  }
  skip_provider_registration = true
}
