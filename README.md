# terraform-azurerm-kubernetes

## Deploys a Kubernetes cluster on AKS with monitoring support through Azure Log Analytics

This Terraform module deploys a Kubernetes cluster on Azure using AKS (Azure Kubernetes Service)

### NOTES

* A SystemAssigned identity will be created by default.
* Kubernetes Version is set to Current.
* Role Based Access Control is always enabled.

## Usage in Terraform 0.15

```terraform
data "azurerm_resource_group" "aksvnetrsg" {
  name = "vnetrsg-aks"
}

data "azurerm_virtual_network" "aksvnet" {
  name                = "vnet-aks"
  resource_group_name = data.azurerm_resource_group.aksvnetrsg.name
}

data "azuread_group" "aks_cluster_admins" {
  name = "AKS-cluster-admins"
}

resource "azurerm_subnet" "akssubnet" {
  name                 = "subnet-aksnodes"
  resource_group_name  = data.azurerm_resource_group.aksvnetrsg.name
  virtual_network_name = data.azurerm_virtual_network.aksvnet.name
  address_prefixes     = ["10.100.10.0/24"]
}

module "aks" {
  source                    = "visma-raet/azure/aks"
  name                      = "aksname"
  resource_group_name       = "rsg-aks"
  location                  = "westeurope"
  prefix                    = "aksdns"
  sku_tier                  = "Free"
  create_resource_group     = true
  agents_availability_zones = ["1", "2"]
  private_cluster_enabled   = false # default value
  vnet_subnet_id            = azurerm_subnet.akssubnet.id
  create_ingress            = false
}

resource "azurerm_role_assignment" "resource_group" {
  scope                = data.azurerm_resource_group.aksvnetrsg.id
  role_definition_name = "Network Contributor"
  principal_id         = module.aks.system_assigned_identity[0].principal_id
}
```

The module supports some outputs that may be used to configure a kubernetes
provider after deploying an AKS cluster.

```terraform
provider "kubernetes" {
  host                   = module.aks.host
  client_certificate     = base64decode(module.aks.client_certificate)
  client_key             = base64decode(module.aks.client_key)
  cluster_ca_certificate = base64decode(module.aks.cluster_ca_certificate)
}
```

## Authors

Originally created by [Jose Angel Munoz](http://github.com/imjoseangel)

## License

[MIT](LICENSE)
