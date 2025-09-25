#!/bin/bash

# ============================
# CONFIGURATION
# ============================
KEYVAULT_NAME="akv-tdsif-sif-ci-sec-01"
SECRET_NAME="githubpat"

# ============================
# FETCH GITHUB PAT FROM KEY VAULT
# ============================
echo "Fetching GitHub PAT from Azure Key Vault..."
GITHUB_PAT=$(az keyvault secret show \
  --vault-name "$KEYVAULT_NAME" \
  --name "$SECRET_NAME" \
  --query value -o tsv)

if [[ -z "$GITHUB_PAT" ]]; then
  echo "❌ Failed to fetch GitHub PAT"
  exit 1
fi

echo "✅ GitHub PAT retrieved successfully"

# ============================
# CALL GITHUB API TO LIST ORGANIZATIONS
# ============================
echo "Fetching GitHub organizations..."

orgs=$(curl -s -H "Authorization: token $GITHUB_PAT" \
  https://api.github.com/user/orgs | jq -r '.[].login')

if [[ -z "$orgs" ]]; then
  echo "❌ No organizations found (or invalid PAT)"
  exit 1
fi

echo "✅ Organizations accessible with this PAT:"
echo "$orgs"
