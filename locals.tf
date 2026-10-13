locals {
  # These are AKS agent-node counts. AKS control plane/master nodes are managed by Azure
  # and are not included in these numbers.
  node_counts = {
    dev  = 1
    test = 2
    prod = 3
  }

  # Example SKU mapping only. Verify SKU availability and quota in var.location before apply.
  # Larger SKUs, especially for prod, will cost more.
  vm_sizes = {
    dev  = "Standard_D4s_v5"
    test = "Standard_D4s_v6"
    prod = "Standard_D8s_v5"
  }
}
