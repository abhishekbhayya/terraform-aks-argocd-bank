$ErrorActionPreference = "Stop"

$ACR_NAME = "abhishekregis734"
$ACR_LOGIN_SERVER = "$ACR_NAME.azurecr.io"

$SOURCE_REGISTRY = "us-central1-docker.pkg.dev/bank-of-anthos-ci/bank-of-anthos"

$IMAGES = @(
    "balancereader:v0.6.4",
    "contacts:v0.6.4",
    "frontend:v0.6.4",
    "ledgerwriter:v0.6.4",
    "loadgenerator:v0.6.4",
    "transactionhistory:v0.6.4",
    "userservice:v0.6.4"
)

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Bank of Anthos -> Azure Container Registry" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "ACR: $ACR_LOGIN_SERVER" -ForegroundColor Yellow
Write-Host ""

# Check Azure login
Write-Host "[1/3] Checking Azure login..." -ForegroundColor Cyan

az account show --query "{Subscription:id,User:user.name}" -o table

if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI is not logged in. Run 'az login' first."
}

Write-Host "Azure login OK." -ForegroundColor Green
Write-Host ""

# Import images
Write-Host "[2/3] Importing Bank of Anthos images..." -ForegroundColor Cyan
Write-Host ""

foreach ($IMAGE in $IMAGES) {

    $SOURCE = "$SOURCE_REGISTRY/$IMAGE"
    $TARGET = "bank-of-anthos/$IMAGE"

    Write-Host "Importing: $IMAGE" -ForegroundColor Yellow

    az acr import `
        --name $ACR_NAME `
        --source $SOURCE `
        --image $TARGET

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to import image: $IMAGE"
    }

    Write-Host "  SUCCESS: $TARGET" -ForegroundColor Green
    Write-Host ""
}

# Verify repositories
Write-Host "[3/3] Verifying ACR repositories..." -ForegroundColor Cyan
Write-Host ""

az acr repository list `
    --name $ACR_NAME `
    --output table

if ($LASTEXITCODE -ne 0) {
    throw "Failed to list ACR repositories."
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " All Bank of Anthos images imported!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "ACR: $ACR_LOGIN_SERVER" -ForegroundColor Green
Write-Host ""