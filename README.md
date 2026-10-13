# Terraform AKS + Argo CD + Bank of Anthos

A learning project that provisions Azure infrastructure with Terraform,
installs Argo CD on Azure Kubernetes Service (AKS), imports application
container images into Azure Container Registry (ACR), and uses Argo CD
to deploy Bank of Anthos from a GitOps repository.

> **Status:** Learning/demo project. Review the Terraform plan, Azure
> permissions, image sources, and networking before deploying. The
> current bootstrap script exposes Argo CD through a public LoadBalancer
> and prints the initial admin password to the terminal. Do not use this
> setup for production without hardening it.

## Architecture

``` mermaid
flowchart TD
    Dev[Developer / PowerShell] -->|Azure CLI login and Terraform| TF[Terraform]
    TF --> RG[Azure Resource Group]
    RG --> VNET[VNet and Subnet]
    RG --> AKS[Azure Kubernetes Service]
    RG --> ACR[Azure Container Registry]
    RG --> KV[Azure Key Vault]
    RG --> PIP[Static Public IP for Argo CD]
    TF -->|local-exec| IMG[Image import PowerShell script]
    IMG -->|az acr import| ACR
    TF -->|local-exec after AKS and dependencies| BOOT[Argo CD bootstrap PowerShell script]
    BOOT -->|kubectl| AKS
    PIP -->|attached to argocd-server Service| ARGO[Argo CD on AKS]
    ACR -->|AcrPull permission for AKS kubelet identity| AKS
    KV -->|stores kubeconfig secret| TF
    GIT[GitOps repository: kubernetes-manifests] -->|Argo CD watches and syncs| ARGO
    ARGO -->|reconciles manifests| BOA[Bank of Anthos workloads]
    BOA -->|frontend Service: LoadBalancer| APPIP[Frontend public endpoint]
```

### Deployment flow

1.  Terraform creates the resource group, VNet/subnet, AKS cluster, ACR,
    Key Vault, public IP, and role assignments.
2.  The image-import script copies the configured Bank of Anthos images
    into ACR.
3.  The bootstrap script obtains temporary AKS credentials, installs
    Argo CD, configures the Argo CD LoadBalancer to use the
    Terraform-created public IP, and creates an Argo CD Application.
4.  Argo CD watches the configured Git repository and syncs the
    `kubernetes-manifests` path into the cluster.
5.  Kubernetes pulls images and runs the Bank of Anthos components.

## Repository layout

``` text
.
├── main.tf
├── provider.tf
├── variable.tf
├── output.tf
├── locals.tf
├── dev.tfvars
├── test.tfvars
├── prod.tfvars
├── scripts/
│   ├── bootstrap-argocd.ps1
│   └── import-bank-of-anthos-images.ps1
├── README.md
├── .gitignore
└── ARCHITECTURE-DIAGRAM.pdf
```

Keep the Terraform files and `scripts/` directory together because
Terraform calls the scripts using paths relative to the project
directory.

## Prerequisites

Install Azure CLI (`az`), Terraform, `kubectl`, PowerShell, and Git. The
bootstrap script requires `kubectl` in `PATH`; Azure CLI can install it
with `az aks install-cli`.

You also need an Azure subscription with sufficient quota and VM
capacity in the selected region, permission to create the required
resources and role assignments, a globally unique ACR name, and access
to the GitOps repository configured in `scripts/bootstrap-argocd.ps1`.

The Terraform configuration pins AzureRM provider `5.0.0` and may use
AzureAD and Random providers, depending on the checked-in version.

## Azure authentication

Use an interactive login for a personal learning subscription or a
service principal for repeatable automation. Never commit credentials to
Git.

### Option A --- Interactive login

``` powershell
az login
az account list --output table
az account set --subscription "<SUBSCRIPTION_ID_OR_NAME>"
az account show --output table
```

### Option B --- Create a service principal

Run this as an identity authorized to create service principals and role
assignments. Replace the subscription ID with your own.

``` powershell
$subscriptionId = "<SUBSCRIPTION_ID>"
az account set --subscription $subscriptionId

az ad sp create-for-rbac `
  --name "sp-terraform-aks-lab" `
  --role "Contributor" `
  --scopes "/subscriptions/$subscriptionId"
```

Save the returned `appId`, `password`, and `tenant` securely. The
password is shown only at creation time. Never paste it into a README,
source file, screenshot, or commit.

**Role-assignment permission is also required.** This project creates
role assignments for Key Vault access, AKS-to-ACR image pulls, and AKS
networking. `Contributor` alone generally cannot create role
assignments. Ask a subscription administrator to grant
`User Access Administrator` or `Role Based Access Control Administrator`
at the appropriate scope. Use `Owner` only for a disposable lab
subscription if explicitly permitted; it is highly privileged.

### Set credentials as environment variables (PowerShell)

These variables apply to the current PowerShell session only. Replace
placeholders with the values returned by Azure CLI.

``` powershell
$env:ARM_CLIENT_ID       = "<APP_ID>"
$env:ARM_CLIENT_SECRET   = "<SP_PASSWORD>"
$env:ARM_TENANT_ID       = "<TENANT_ID>"
$env:ARM_SUBSCRIPTION_ID = "<SUBSCRIPTION_ID>"

az login --service-principal `
  --username $env:ARM_CLIENT_ID `
  --password $env:ARM_CLIENT_SECRET `
  --tenant $env:ARM_TENANT_ID

az account set --subscription $env:ARM_SUBSCRIPTION_ID
az account show --output table
```

The AzureRM provider reads the `ARM_*` environment variables. The
PowerShell scripts also call Azure CLI and `kubectl`, so Azure CLI must
be authenticated in the same environment.

## Register Azure resource providers

Provider registration is subscription-level and may require elevated
permissions. Ask your subscription administrator if registration is
denied.

``` powershell
$providers = @(
  "Microsoft.Compute",
  "Microsoft.Network",
  "Microsoft.ContainerService",
  "Microsoft.ContainerRegistry",
  "Microsoft.KeyVault",
  "Microsoft.ManagedIdentity",
  "Microsoft.Authorization",
  "Microsoft.Storage",
  "Microsoft.Insights"
)

foreach ($provider in $providers) {
  az provider register --namespace $provider
}

foreach ($provider in $providers) {
  az provider show --namespace $provider `
    --query "{Namespace:namespace,State:registrationState}" `
    --output table
}
```

Wait for required providers to show `Registered` before running
Terraform. Additional providers may be needed depending on enabled Azure
features.

## Configure the environment

Use the appropriate variable file:

-   `dev.tfvars`
-   `test.tfvars`
-   `prod.tfvars`

  Environment     Intended AKS agent/worker nodes Example VM SKU
  ------------- --------------------------------- -------------------
  Dev                                           1 `Standard_D4s_v5`
  Test                                          2 `Standard_D4s_v6`
  Prod                                          3 `Standard_D8s_v5`

AKS is a managed Kubernetes service; Azure manages the control plane.
These counts refer to worker/agent nodes, not master/control-plane
nodes. VM SKUs are examples only: verify regional availability,
subscription quota, and cost before applying. One-node dev is for
learning and has limited resilience.

Set a globally unique ACR name in the `.tfvars` file and keep it
consistent with `scripts/import-bank-of-anthos-images.ps1`, which
currently hardcodes the ACR name. The import script lists seven images.
The frontend manifest references ACR, while database manifests may still
reference Google Artifact Registry. Verify all image references and
import any missing images before expecting every component to run from
ACR.

> **Environment limitation:** The supplied environment files use the
> same ACR name by default. Azure requires each registry name to be
> globally unique. Treat this as a single-environment-at-a-time demo
> unless you deliberately configure a shared ACR or unique registry
> names per environment and update the import script. Use separate
> Terraform state for environments that must run concurrently.

## Initialize, validate, plan, and apply

Run commands from the directory containing the `.tf` files and
`scripts/`.

``` powershell
terraform init
terraform fmt -recursive
terraform validate

# Start with dev. Review the complete plan before applying.
terraform plan -var-file="dev.tfvars" -out="dev.tfplan"
terraform show "dev.tfplan"
terraform apply "dev.tfplan"
```

To plan another environment, explicitly select its file:

``` powershell
terraform plan -var-file="test.tfvars"
terraform plan -var-file="prod.tfvars"
```

Terraform does not automatically load these environment-specific files;
specify `-var-file`. Applying a different environment with the same
state will generally reconcile existing resources to the new values,
rather than create an independent environment. Use separate backend
state keys or workspaces and environment-specific resource names for
concurrent environments.

The `local-exec` provisioners run on the machine executing Terraform.
Keep the scripts in the expected `scripts/` directory and ensure `az`,
`kubectl`, network access, and GitHub access are available.

## Verify the deployment

The environment-aware configuration generates the Key Vault name. The
following commands use a Terraform output named `key_vault_name`; add
that output to `output.tf` if it is not already present.

``` hcl
output "key_vault_name" {
  description = "Generated Azure Key Vault name"
  value       = azurerm_key_vault.keyvault.name
}
```

Then retrieve kubeconfig using the generated name rather than a
hardcoded vault name:

``` powershell
# Get the generated Key Vault name from Terraform
$vaultName = terraform output -raw key_vault_name

# Retrieve kubeconfig from Key Vault
$kubeconfigContent = az keyvault secret show `
  --vault-name $vaultName `
  --name kubeconfig `
  --query value `
  -o tsv

# Write UTF-8 without a BOM
[System.IO.File]::WriteAllText(
  "$PWD\aks-kubeconfig",
  $kubeconfigContent,
  [System.Text.UTF8Encoding]::new($false)
)

$env:KUBECONFIG = "$PWD\aks-kubeconfig"

kubectl get nodes
kubectl get pods -n argocd
kubectl get svc -n argocd
kubectl get applications -n argocd
kubectl get pods -n default
kubectl get svc -n default
```

Your Azure identity needs permission to read the `kubeconfig` secret. If
Key Vault uses Azure RBAC, an appropriate role such as
`Key Vault Secrets User` may be required.

The bootstrap script prints the Argo CD URL, username (`admin`), and
initial admin password in the terminal. Keep that output private. To
retrieve the initial password again after connecting to the cluster:

``` powershell
$encoded = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
```

Change the initial password after first login and do not store it in Git
or Terraform outputs. The current bootstrap script prints an HTTPS URL
using the Argo CD public IP; it does not configure a custom domain or
TLS certificate. The frontend URL printed by the current script is
hardcoded, so verify the actual frontend external IP with
`kubectl get svc -n default` rather than assuming the printed URL is
current.

## Security notes

-   Do not commit Terraform state, saved plan files, kubeconfigs,
    service-principal secrets, passwords, or private keys.
-   Use `.gitignore` to exclude state, local credentials, and any
    `.tfvars` files containing secrets. Commit example `.tfvars` files
    only when they contain non-secret configuration.
-   Terraform state may contain raw kubeconfig because the configuration
    stores it in Key Vault. Key Vault storage does not remove the secret
    from Terraform state. Use a remote, access-controlled backend with
    encryption and restricted access before handling sensitive data.
-   The current Key Vault setting has purge protection disabled; review
    the recovery and security implications before using it beyond a
    disposable lab.
-   Argo CD is publicly exposed by a LoadBalancer. Restrict access or
    use private access and TLS before production use.
-   Review the GitOps manifests for demo credentials, JWT key material,
    public LoadBalancer services, and database persistence. This project
    is for learning, not production financial workloads.

## Cleanup

Review the plan and destroy only the environment you intend to remove:

``` powershell
terraform plan -destroy -var-file="dev.tfvars"
terraform destroy -var-file="dev.tfvars"
```

If a Kubernetes Service uses a public IP, delete that Service before
deleting the AKS cluster or public IP. Azure-managed LoadBalancer
resources can otherwise cause dependency errors. Verify in the Azure
portal that the resource group, AKS managed resource group, public IPs,
ACR, and other billable resources are removed when finished. Keep a
shared ACR only if you intentionally want to retain it.

## Learning goals

-   Infrastructure as Code with Terraform
-   Azure networking and managed AKS
-   Azure Container Registry and managed identity (`AcrPull`)
-   Azure Key Vault and RBAC
-   PowerShell automation with Azure CLI and `kubectl`
-   GitOps with Argo CD and automated sync/self-heal

## License and attribution

Bank of Anthos is a Google sample application. Follow the original
project's license and attribution requirements for manifests or images
reused here. This repository's Terraform and automation code is a
learning project; review the licenses of all dependencies and upstream
assets before redistribution.
