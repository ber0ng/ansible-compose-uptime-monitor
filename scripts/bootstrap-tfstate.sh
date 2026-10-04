#!/usr/bin/env bash
# One-time setup: storage account for Terraform remote state.
# Uses Entra ID auth only (shared keys disabled), so no storage keys exist to leak.
set -euo pipefail

# Stop Git Bash from mangling Azure resource IDs like /subscriptions/...
export MSYS_NO_PATHCONV=1

LOCATION="eastus"
RG="rg-pulsecheck-tfstate"
SA="${1:-stpulsetf$RANDOM}"   # must be globally unique, 3-24 lowercase letters/numbers
CONTAINER="tfstate"

echo "Creating resource group $RG..."
az group create --name "$RG" --location "$LOCATION" \
  --tags project=pulsecheck purpose=tfstate -o none

echo "Creating storage account $SA..."
az storage account create \
  --name "$SA" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  -o none

echo "Enabling blob versioning (lets you recover an older state file)..."
az storage account blob-service-properties update \
  --account-name "$SA" --resource-group "$RG" \
  --enable-versioning true -o none

echo "Granting you Storage Blob Data Contributor on the account..."
SA_ID=$(az storage account show --name "$SA" --resource-group "$RG" --query id -o tsv)
USER_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create \
  --assignee-object-id "$USER_ID" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$SA_ID" -o none

echo "Creating container (retrying while the role assignment propagates)..."
for i in {1..12}; do
  if az storage container create --name "$CONTAINER" --account-name "$SA" --auth-mode login -o none 2>/dev/null; then
    echo "Container created."
    break
  fi
  if [ "$i" -eq 12 ]; then
    echo "Gave up waiting. Re-run the script with the same name: $0 $SA"
    exit 1
  fi
  echo "  waiting for permissions... ($i/12)"
  sleep 10
done

echo
echo "Done. Put this in terraform/backend.hcl:"
echo "  resource_group_name  = \"$RG\""
echo "  storage_account_name = \"$SA\""
echo "  container_name       = \"$CONTAINER\""
echo "  key                  = \"pulsecheck.tfstate\""
echo "  use_azuread_auth     = true"