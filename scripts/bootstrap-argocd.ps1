param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [string]$GitRepoUrl = "https://github.com/abhishekbhayya/gitops-configs.git",

    [string]$GitRevision = "main",

    [string]$GitPath = "kubernetes-manifests" ,

    [string]$PublicIpName = "pip-argocd"
)

$ErrorActionPreference = "Stop"

# Azure CLI installs kubectl here on Windows
$kubectlPath = Join-Path $HOME ".azure-kubectl"

if (Test-Path $kubectlPath) {
    $env:Path += ";$kubectlPath"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "      AKS Argo CD Bootstrap" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# 1. Check required commands
# ------------------------------------------------------------

Write-Host "[1/8] Checking required tools..." -ForegroundColor Yellow

$kubectlPath = Join-Path $HOME ".azure-kubectl"

if (Test-Path $kubectlPath) {
    $env:Path += ";$kubectlPath"
}

$requiredCommands = @("az", "kubectl")

foreach ($command in $requiredCommands) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command was not found in PATH."
    }

    Write-Host "  $command found." -ForegroundColor Green
}

# ------------------------------------------------------------
# 2. Create temporary kubeconfig
# ------------------------------------------------------------

Write-Host ""
Write-Host "[2/8] Getting AKS credentials..." -ForegroundColor Yellow

$tempKubeconfig = Join-Path $env:TEMP "aks-argocd-bootstrap-$ClusterName.yaml"

if (Test-Path $tempKubeconfig) {
    Remove-Item $tempKubeconfig -Force
}

az aks get-credentials `
    --resource-group $ResourceGroupName `
    --name $ClusterName `
    --file $tempKubeconfig `
    --overwrite-existing

if (-not (Test-Path $tempKubeconfig)) {
    throw "Failed to create temporary kubeconfig."
}

$env:KUBECONFIG = $tempKubeconfig

Write-Host "  Temporary kubeconfig created." -ForegroundColor Green

# ------------------------------------------------------------
# 3. Verify AKS connectivity
# ------------------------------------------------------------

Write-Host ""
Write-Host "[3/8] Verifying AKS connectivity..." -ForegroundColor Yellow

kubectl get nodes

if ($LASTEXITCODE -ne 0) {
    throw "kubectl could not connect to AKS."
}

Write-Host "  AKS connection successful." -ForegroundColor Green

# ------------------------------------------------------------
# 4. Install Argo CD
# ------------------------------------------------------------

Write-Host ""
Write-Host "[4/8] Installing Argo CD..." -ForegroundColor Yellow


$namespaceExists = kubectl get namespace argocd --ignore-not-found -o name 2>$null

if (-not $namespaceExists) {
    kubectl create namespace argocd
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create argocd namespace."
    }
    Write-Host "  Namespace argocd created." -ForegroundColor Green
}
else {
    Write-Host "  Namespace argocd already exists." -ForegroundColor DarkGray
}

kubectl apply `
    -n argocd `
    --server-side `
    --force-conflicts `
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

if ($LASTEXITCODE -ne 0) {
    throw "Argo CD installation failed."
}

Write-Host "  Argo CD manifests applied." -ForegroundColor Green

# ------------------------------------------------------------
# 5. Wait for Argo CD server
# ------------------------------------------------------------

Write-Host ""
Write-Host "[5/8] Waiting for Argo CD..." -ForegroundColor Yellow

kubectl wait `
    --namespace argocd `
    --for=condition=Available `
    deployment/argocd-server `
    --timeout=300s

if ($LASTEXITCODE -ne 0) {
    throw "Argo CD server did not become ready within 5 minutes."
}

Write-Host "  Argo CD server is ready." -ForegroundColor Green


# ------------------------------------------------------------
# 6. Configure Azure public IP for Argo CD
# ------------------------------------------------------------

Write-Host ""
Write-Host "[6/8] Configuring Argo CD public IP..." -ForegroundColor Yellow

# Get the public IP address created by Terraform
$publicIp = az network public-ip show `
    --resource-group $ResourceGroupName `
    --name $PublicIpName `
    --query ipAddress `
    -o tsv

if ($LASTEXITCODE -ne 0 -or -not $publicIp) {
    throw "Could not retrieve public IP '$PublicIpName'. Check Terraform deployment."
}

Write-Host "  Public IP: $publicIp" -ForegroundColor Green




# Attach the Terraform-created public IP to Argo CD
$servicePatch = @{
    metadata = @{
        annotations = @{
            "service.beta.kubernetes.io/azure-pip-name" = $PublicIpName
            "service.beta.kubernetes.io/azure-load-balancer-resource-group" = $ResourceGroupName
        }
    }
    spec = @{
        type = "LoadBalancer"
    }
} | ConvertTo-Json -Depth 5 -Compress

# Write JSON to a temporary file
$patchFile = Join-Path $env:TEMP "argocd-service-patch.json"

try {
    Set-Content -Path $patchFile -Value $servicePatch -Encoding utf8

    kubectl patch service argocd-server `
        --namespace argocd `
        --type merge `
        --patch-file $patchFile

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure the Argo CD LoadBalancer service."
    }
}
finally {
    if (Test-Path $patchFile) {
        Remove-Item $patchFile -Force
    }
}

# Wait for Azure to assign the external IP
Write-Host "  Waiting for Azure LoadBalancer provisioning..." -ForegroundColor Yellow

$assignedIp = ""

for ($i = 0; $i -lt 60; $i++) {
    $assignedIp = kubectl get service argocd-server `
        --namespace argocd `
        -o jsonpath="{.status.loadBalancer.ingress[0].ip}" 2>$null

    if ($assignedIp -eq $publicIp) {
        break
    }

    Start-Sleep -Seconds 10
}

if ($assignedIp -ne $publicIp) {
    kubectl describe service argocd-server -n argocd
    throw "Argo CD did not receive the expected IP $publicIp within 10 minutes."
}

Write-Host "  Argo CD public IP attached successfully." -ForegroundColor Green


# ------------------------------------------------------------
# 6. Create Argo CD Application
# ------------------------------------------------------------

Write-Host ""
Write-Host "[7/8] Creating Argo CD Application..." -ForegroundColor Yellow

$applicationYaml = @"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bank-of-anthos
  namespace: argocd
spec:
  project: default

  source:
    repoURL: $GitRepoUrl
    targetRevision: $GitRevision
    path: $GitPath

  destination:
    server: https://kubernetes.default.svc
    namespace: default

  syncPolicy:
    automated:
      prune: true
      selfHeal: true

    syncOptions:
      - CreateNamespace=true
"@

$applicationYaml | kubectl apply -f -

if ($LASTEXITCODE -ne 0) {
    throw "Failed to create Argo CD Application."
}

Write-Host "  Argo CD Application created." -ForegroundColor Green

# ------------------------------------------------------------
# 7. Show final status
# ------------------------------------------------------------

Write-Host ""
Write-Host "[8/8] Checking final status..." -ForegroundColor Yellow

Write-Host ""
Write-Host "Argo CD Application:" -ForegroundColor Cyan

kubectl get application bank-of-anthos -n argocd

Write-Host ""
Write-Host "Argo CD Service:" -ForegroundColor Cyan

kubectl get service argocd-server -n argocd

Write-Host ""
Write-Host "Bank of Anthos resources:" -ForegroundColor Cyan

kubectl get pods -n default

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "       Argo CD Bootstrap Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

Write-Host "Argo CD Service:" -ForegroundColor Cyan
kubectl get service argocd-server -n argocd

Write-Host ""
Write-Host "Bank of Anthos URL:" -ForegroundColor Cyan
Write-Host "http://4.241.3.195" -ForegroundColor White

Write-Host ""
Write-Host "Argo CD URL:" -ForegroundColor Cyan
Write-Host "https://$publicIp" -ForegroundColor White

Write-Host ""
Write-Host "Initial admin password:" -ForegroundColor Cyan

$passwordEncoded = kubectl -n argocd get secret argocd-initial-admin-secret `
    -o jsonpath="{.data.password}"

if ($passwordEncoded) {
    $password = [System.Text.Encoding]::UTF8.GetString(
        [System.Convert]::FromBase64String($passwordEncoded)
    )

    Write-Host $password -ForegroundColor White
}

Write-Host ""
Write-Host "Username: admin" -ForegroundColor White
Write-Host ""

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

if (Test-Path $tempKubeconfig) {
    Remove-Item $tempKubeconfig -Force
}

Remove-Item Env:\KUBECONFIG -ErrorAction SilentlyContinue