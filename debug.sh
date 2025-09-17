#!/usr/bin/env bash

# Debug script to troubleshoot GitHub API issue
# Run this to identify the problem

KEY_VAULT_NAME="akv-tdsif-sif-ci-sec-01"
GITHUB_TOKEN_SECRET_NAME="githubpat"
GITHUB_API="https://api.github.com"

echo "=== GitHub API Debug Script ==="
echo ""

# Step 1: Check Azure CLI
echo "1. Checking Azure CLI..."
if ! command -v az &> /dev/null; then
    echo "❌ Azure CLI not found"
    exit 1
fi

if ! az account show &> /dev/null; then
    echo "❌ Not logged into Azure"
    echo "Run: az login"
    exit 1
fi

echo "✅ Azure CLI authenticated"
echo ""

# Step 2: Fetch token from Key Vault
echo "2. Fetching GitHub token from Key Vault..."
GITHUB_TOKEN=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$GITHUB_TOKEN_SECRET_NAME" --query value -o tsv 2>/dev/null)

if [[ -z "$GITHUB_TOKEN" ]]; then
    echo "❌ Failed to fetch GitHub token from Key Vault"
    echo "Checking if secret exists..."
    az keyvault secret list --vault-name "$KEY_VAULT_NAME" --query "[].name" -o tsv | grep -i git || echo "No GitHub secrets found"
    exit 1
fi

echo "✅ GitHub token fetched successfully"
echo "Token length: ${#GITHUB_TOKEN} characters"
echo "Token preview: ${GITHUB_TOKEN:0:10}..."
echo ""

# Step 3: Check token format
echo "3. Validating GitHub token format..."
if [[ "$GITHUB_TOKEN" =~ ^ghp_[a-zA-Z0-9]{36}$ ]]; then
    echo "✅ Token format looks correct (classic PAT)"
elif [[ "$GITHUB_TOKEN" =~ ^github_pat_[a-zA-Z0-9_]{82}$ ]]; then
    echo "✅ Token format looks correct (fine-grained PAT)"
elif [[ "$GITHUB_TOKEN" =~ ^gho_[a-zA-Z0-9]{36}$ ]]; then
    echo "✅ Token format looks correct (OAuth token)"
else
    echo "⚠️  Token format doesn't match expected patterns"
    echo "Expected: ghp_... (36 chars) or github_pat_... (82+ chars)"
    echo "Got: ${GITHUB_TOKEN:0:20}... (${#GITHUB_TOKEN} chars total)"
fi
echo ""

# Step 4: Test basic GitHub API
echo "4. Testing basic GitHub API access..."
echo "Calling: GET $GITHUB_API/user"
USER_RESPONSE=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/user")

if [[ -z "$USER_RESPONSE" ]]; then
    echo "❌ Empty response from GitHub API"
    exit 1
fi

echo "Raw response preview: ${USER_RESPONSE:0:200}..."
echo ""

# Check if response contains error
if echo "$USER_RESPONSE" | jq -e '.message' >/dev/null 2>&1; then
    echo "❌ GitHub API returned an error:"
    echo "$USER_RESPONSE" | jq -r '.message'
    echo ""
    echo "Full response:"
    echo "$USER_RESPONSE" | jq '.'
    exit 1
fi

# Check if we got user info
if echo "$USER_RESPONSE" | jq -e '.login' >/dev/null 2>&1; then
    USERNAME=$(echo "$USER_RESPONSE" | jq -r '.login')
    echo "✅ Successfully authenticated as: $USERNAME"
else
    echo "❌ Unexpected response format:"
    echo "$USER_RESPONSE"
    exit 1
fi
echo ""

# Step 5: Test organizations API
echo "5. Testing organizations API..."
echo "Calling: GET $GITHUB_API/user/orgs"
ORGS_RESPONSE=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/user/orgs")

if [[ -z "$ORGS_RESPONSE" ]]; then
    echo "❌ Empty response from orgs API"
    exit 1
fi

echo "Raw orgs response preview: ${ORGS_RESPONSE:0:200}..."
echo ""

# Check if response is an array
if ! echo "$ORGS_RESPONSE" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "❌ Organizations response is not an array"
    echo "Response type: $(echo "$ORGS_RESPONSE" | jq -r 'type' 2>/dev/null || echo "invalid JSON")"
    
    # Check for error message
    if echo "$ORGS_RESPONSE" | jq -e '.message' >/dev/null 2>&1; then
        echo "Error message: $(echo "$ORGS_RESPONSE" | jq -r '.message')"
    fi
    
    echo "Full response:"
    echo "$ORGS_RESPONSE"
    exit 1
fi

# Extract org names
ORG_COUNT=$(echo "$ORGS_RESPONSE" | jq '. | length')
echo "✅ Found $ORG_COUNT organizations"

if [[ "$ORG_COUNT" -gt 0 ]]; then
    echo "Organizations:"
    echo "$ORGS_RESPONSE" | jq -r '.[].login' | while read org; do
        echo "  - $org"
    done
else
    echo "⚠️  No organizations found. This could mean:"
    echo "   - User is not a member of any organizations"
    echo "   - Token doesn't have 'read:org' scope"
    echo "   - Organizations are private and token lacks permissions"
fi
echo ""

# Step 6: Check token scopes
echo "6. Checking token scopes..."
SCOPES_RESPONSE=$(curl -s -I -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/user")
SCOPES=$(echo "$SCOPES_RESPONSE" | grep -i 'x-oauth-scopes:' | cut -d':' -f2- | tr -d '\r\n' | sed 's/^[[:space:]]*//')

if [[ -n "$SCOPES" ]]; then
    echo "✅ Token scopes: $SCOPES"
    
    if [[ "$SCOPES" =~ read:org ]] || [[ "$SCOPES" =~ admin:org ]]; then
        echo "✅ Token has organization read permissions"
    else
        echo "⚠️  Token may lack 'read:org' scope for organization access"
    fi
else
    echo "⚠️  Could not determine token scopes"
fi

echo ""
echo "=== Debug Complete ==="
echo ""
echo "Summary:"
echo "- Azure Key Vault: ✅ Working"
echo "- GitHub Token: ✅ Retrieved"
echo "- GitHub API: $(echo "$USER_RESPONSE" | jq -e '.login' >/dev/null 2>&1 && echo "✅ Working" || echo "❌ Issues")"
echo "- Organizations: $(echo "$ORGS_RESPONSE" | jq -e 'type == "array"' >/dev/null 2>&1 && echo "✅ Working" || echo "❌ Issues")"
