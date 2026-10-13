Environment configuration files

Use exactly one environment file per Terraform run:
  terraform plan -var-file="dev.tfvars"
  terraform apply -var-file="dev.tfvars"

Replace dev with test or prod as needed.

Important:
- This design creates one environment per Terraform state/workspace. Do not switch var-files against the same state expecting separate environments; use separate state/workspaces or destroy the old environment first.
- The import script hardcodes ACR name abhishekregis734. Keep acr_name matching it unless you also parameterize the script.
- ACR names are globally unique. These files intentionally use the same ACR name, so they are not designed to create dev, test and prod ACRs simultaneously. To run environments simultaneously, use a shared ACR or update the import script to accept a per-environment ACR name.
- AKS control plane/master nodes are managed by Azure. node_counts means AKS agent/worker nodes: dev=1, test=2, prod=3. It does NOT mean one master plus the listed worker count.
- The VM SKU map is illustrative. Verify regional capacity and quota before apply. Prod's Standard_D8s_v5 with three nodes may be expensive.
- Azure resource creation can consume credits. Review terraform plan before apply.
- The Key Vault stores kubeconfig. Terraform state may also contain sensitive kubeconfig material; protect state and never commit it to Git.
- The bootstrap script prints the initial Argo CD admin password. Treat terminal output as sensitive and change the password after first login.
- The script prints a hardcoded Bank of Anthos URL; that URL may be stale and should not be relied on.
- No explicit NSG resource is declared here. AKS/networking prerequisites and company policy may still require NSG permissions or a preconfigured subnet.
