#!/usr/bin/env bash

# --- CONFIGURATION ---
GITHUB_API="https://api.github.com"

# Azure Key Vault Configuration - UPDATED WITH YOUR VALUES
KEY_VAULT_NAME="akv-tdsif-sif-ci-sec-01"  # Your actual Key Vault name
GITHUB_TOKEN_SECRET_NAME="githubpat"       # Your actual secret name
AZDO_PAT_DEV_SECRET_NAME="azdo-pat-dev"
AZDO_PAT_HE_SECRET_NAME="azdo-pat-he"

# Azure Authentication Configuration (Optional - for automated environments)
# Uncomment and configure these for automated authentication:
# AZURE_CLIENT_ID=""          # Service Principal Application ID
# AZURE_CLIENT_SECRET=""      # Service Principal Secret
# AZURE_TENANT_ID=""          # Azure Tenant ID
# AZURE_SUBSCRIPTION_ID=""    # Azure Subscription ID

# Initialize token variables
GITHUB_TOKEN=""
AZDO_PAT_DEV=""
AZDO_PAT_HE=""

# Other configurations remain the same
AZDO_ORG_DEV="TDL-TCP-DEV"
AZDO_ORG_HE="TDL-TCP-HE"
CSV_DEV="Dev-Pipelines.csv"
CSV_HE="HE-Pipelines.csv"
OWNERS_DIR="owners_list"
IGNORE_CSV="ignore.csv"
target_branches_regex="^(main|staging|release)$"

# Special mapping for strategic initiative
STRATEGIC_INITIATIVE_GITHUB_ORG="tatadigital-strategic-initiative"
STRATEGIC_INITIATIVE_ADO_PROJECT="TDL%20Strategic%20Initiatives"

# Note: For standalone repos (pull-request-validation-*), only GitHub webhook checking is performed
# No Azure DevOps pipeline mapping or checking required
 
declare -A PIPELINE_LOOKUP_DEV
declare -A PIPELINE_LOOKUP_HE
declare -A NON_COMPLIANT_REPOS
declare -A OWNERS_LOOKUP
declare -A IGNORE_LOOKUP

# Logging function with IST time
log() {
  local ist_time=$(TZ='Asia/Kolkata' date +"%Y-%m-%d %H:%M:%S IST")
  echo "[$ist_time] $*"
}

# Function to check if Azure CLI is installed and authenticated
check_azure_cli() {
  log "Checking Azure CLI availability..."
  
  if ! command -v az &> /dev/null; then
    log "Error: Azure CLI is not installed or not in PATH"
    log "Please install Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
  fi
  
  # Try automated login first if service principal credentials are provided
  if [[ -n "${AZURE_CLIENT_ID:-}" && -n "${AZURE_CLIENT_SECRET:-}" && -n "${AZURE_TENANT_ID:-}" ]]; then
    log "Attempting automated Azure login with service principal..."
    if az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" --tenant "$AZURE_TENANT_ID" --output none 2>/dev/null; then
      if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
        az account set --subscription "$AZURE_SUBSCRIPTION_ID" --output none
      fi
      log "✓ Successfully authenticated with service principal"
    else
      log "Error: Failed to authenticate with service principal"
      log "Please check your AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, and AZURE_TENANT_ID"
      exit 1
    fi
  else
    # Check if user is already authenticated
    if ! az account show &> /dev/null; then
      log "Error: Not authenticated with Azure CLI and no service principal configured"
      log ""
      log "Options:"
      log "1. Run 'az login' manually before executing this script"
      log "2. Configure service principal authentication (see script comments)"
      log ""
      exit 1
    fi
  fi
  
  local subscription_name=$(az account show --query name -o tsv)
  local subscription_id=$(az account show --query id -o tsv)
  log "✓ Azure CLI authenticated - Subscription: $subscription_name ($subscription_id)"
}

# Function to fetch secret from Azure Key Vault
get_secret_from_akv() {
  local secret_name="$1"
  local secret_value=""
  
  log "Fetching secret '$secret_name' from Key Vault '$KEY_VAULT_NAME'..."
  
  # Try to get the secret
  secret_value=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$secret_name" --query value -o tsv 2>/dev/null)
  
  if [[ $? -ne 0 ]] || [[ -z "$secret_value" ]]; then
    log "Error: Failed to retrieve secret '$secret_name' from Key Vault '$KEY_VAULT_NAME'"
    log "Please ensure:"
    log "  1. Key Vault name is correct: $KEY_VAULT_NAME"
    log "  2. Secret name exists: $secret_name"
    log "  3. You have proper permissions to read secrets from the Key Vault"
    exit 1
  fi
  
  log "✓ Successfully retrieved secret '$secret_name'"
  echo "$secret_value"
}

# Function to load all tokens from Azure Key Vault
load_tokens_from_akv() {
  log "Loading tokens from Azure Key Vault..."
  
  # Check Azure CLI availability and authentication
  check_azure_cli
  
  # Fetch GitHub token (required)
  GITHUB_TOKEN=$(get_secret_from_akv "$GITHUB_TOKEN_SECRET_NAME")
  
  # Try to fetch Azure DevOps tokens (optional - only show warning if not found)
  if az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$AZDO_PAT_DEV_SECRET_NAME" --query value -o tsv >/dev/null 2>&1; then
    AZDO_PAT_DEV=$(get_secret_from_akv "$AZDO_PAT_DEV_SECRET_NAME")
  else
    log "Warning: Azure DevOps DEV token ($AZDO_PAT_DEV_SECRET_NAME) not found - Azure DevOps features will be limited"
    AZDO_PAT_DEV=""
  fi
  
  if az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$AZDO_PAT_HE_SECRET_NAME" --query value -o tsv >/dev/null 2>&1; then
    AZDO_PAT_HE=$(get_secret_from_akv "$AZDO_PAT_HE_SECRET_NAME")
  else
    log "Warning: Azure DevOps HE token ($AZDO_PAT_HE_SECRET_NAME) not found - Azure DevOps features will be limited"
    AZDO_PAT_HE=""
  fi
  
  # Validate that GitHub token was retrieved
  if [[ -z "$GITHUB_TOKEN" ]]; then
    log "Error: GitHub token could not be retrieved from Key Vault"
    exit 1
  fi
  
  log "✓ All tokens successfully loaded from Azure Key Vault"
  log "  GitHub Token: ${GITHUB_TOKEN:0:7}... (${#GITHUB_TOKEN} chars)"
  if [[ -n "$AZDO_PAT_DEV" ]]; then
    log "  Azure DevOps DEV Token: ${AZDO_PAT_DEV:0:7}... (${#AZDO_PAT_DEV} chars)"
  fi
  if [[ -n "$AZDO_PAT_HE" ]]; then
    log "  Azure DevOps HE Token: ${AZDO_PAT_HE:0:7}... (${#AZDO_PAT_HE} chars)"
  fi
}

# Pipeline name cleaning
clean_pipeline_name() {
  local name="$1"
  # Remove common prefixes and clean the name
  echo "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//; s/"$//'
}

# Load ignore CSV to lookup hash map
load_ignore_to_lookup() {
  local ignore_file="$IGNORE_CSV"
  
  # Clear existing entries
  unset IGNORE_LOOKUP
  declare -gA IGNORE_LOOKUP
  
  # Check if ignore file exists
  if [[ ! -f "$ignore_file" ]]; then
    log "Warning: Ignore file not found: $ignore_file"
    log "Proceeding without ignore functionality"
    return 0
  fi
 
  log "Loading ignore CSV: $ignore_file"
  local loaded_count=0
  
  # Read CSV line by line, skip header if present
  {
    # Check if first line is header (contains "org" or "repo" keywords)
    read first_line
    if [[ "$first_line" =~ ^[[:space:]]*[Oo]rg[[:space:]]*,[[:space:]]*[Rr]epo || "$first_line" =~ ^[[:space:]]*[Rr]epo[[:space:]]*,[[:space:]]*[Oo]rg ]]; then
      log "Header detected in ignore.csv, skipping first line"
    else
      # First line is data, process it
      IFS=',' read -r org_name repo_name rest <<< "$first_line"
      org_name=$(echo "$org_name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      repo_name=$(echo "$repo_name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      
      if [[ -n "$org_name" && -n "$repo_name" ]]; then
        local key="${org_name}|${repo_name}"
        IGNORE_LOOKUP["$key"]="true"
        ((loaded_count++))
        log "    Loaded ignore entry: $org_name/$repo_name"
      fi
    fi
    
    # Process remaining lines
    while IFS=',' read -r org_name repo_name rest || [[ -n "$org_name" ]]; do
      # Skip empty lines
      [[ -z "$org_name" && -z "$repo_name" ]] && continue
      
      # Clean the fields
      org_name=$(echo "$org_name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      repo_name=$(echo "$repo_name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      
      # Validate required fields
      [[ -z "$org_name" || -z "$repo_name" ]] && continue
      
      # Set the mapping using org|repo as key
      local key="${org_name}|${repo_name}"
      IGNORE_LOOKUP["$key"]="true"
      ((loaded_count++))
      log "    Loaded ignore entry: $org_name/$repo_name"
    done
  } < "$ignore_file"
  
  if [ $loaded_count -eq 0 ]; then
    log "Warning: No ignore entries loaded from $ignore_file"
    log "Expected format: org_name,repo_name (one per line)"
  else
    log "Loaded $loaded_count ignore entries from $ignore_file"
  fi
}

# Check if a repository should be ignored
should_ignore_repo() {
  local org="$1"
  local repo="$2"
  local key="${org}|${repo}"
  
  if [[ -n "${IGNORE_LOOKUP[$key]:-}" ]]; then
    return 0  # true - should ignore
  else
    return 1  # false - should not ignore
  fi
}

# Load owners CSV to lookup hash map
load_owners_to_lookup() {
  local org="$1"
  local csv_file="$OWNERS_DIR/git_owners_${org}.csv"
  
  # Clear existing entries for this org
  for key in "${!OWNERS_LOOKUP[@]}"; do
    if [[ "$key" =~ ^${org}\| ]]; then
      unset OWNERS_LOOKUP["$key"]
    fi
  done
  
  # Check if CSV file exists
  if [[ ! -f "$csv_file" ]]; then
    log "Warning: Owners file not found: $csv_file"
    log "Will use default owner email for repositories in: $org"
    return 0
  fi
 
  log "Loading owners CSV: $csv_file"
  local loaded_count=0
  
  # Read CSV line by line, skip header
  {
    read # skip header
    while IFS=',' read -r repo_name repo_owner rest || [[ -n "$repo_name" ]]; do
      # Skip empty lines
      [[ -z "$repo_name" && -z "$repo_owner" ]] && continue
      
      # Clean the fields
      repo_name=$(echo "$repo_name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      repo_owner=$(echo "$repo_owner" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      
      # Validate required fields
      [[ -z "$repo_name" || -z "$repo_owner" ]] && continue
      
      # Set the mapping using org|repo as key
      local key="${org}|${repo_name}"
      OWNERS_LOOKUP["$key"]="$repo_owner"
      ((loaded_count++))
    done
  } < "$csv_file"
  
  if [ $loaded_count -eq 0 ]; then
    log "Warning: No owner mappings loaded from $csv_file"
    log "Will use default owner email for repositories in: $org"
  else
    log "Loaded $loaded_count owner mappings from $csv_file"
  fi
}

# Get owner email for a repository
get_owner_email() {
  local org="$1"
  local repo="$2"
  local key="${org}|${repo}"
  
  local email="${OWNERS_LOOKUP[$key]:-}"
  if [[ -z "$email" ]]; then
    echo "no-owner@unknown.com"
  else
    echo "$email"
  fi
}

# Load CSV to lookup hash map with enhanced key structure
load_csv_to_lookup() {
  local file="$1"
  local -n map_ref=$2
 
  if [[ ! -f "$file" ]]; then
    log "Warning: CSV file not found: $file"
    log "Pipeline lookup will be limited for this data source"
    return 0
  fi
 
  log "Loading CSV: $file"
  local loaded_count=0
  local strategic_count=0
  
  # Read CSV line by line, skip header
  {
    read # skip header
    while IFS=',' read -r org project id name rest || [[ -n "$org" ]]; do
      # Skip empty lines
      [[ -z "$org" && -z "$project" && -z "$id" && -z "$name" ]] && continue
      
      # Validate required fields
      [[ -z "$org" || -z "$project" || -z "$id" || -z "$name" ]] && continue
      
      # Clean the fields
      org=$(echo "$org" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      project=$(echo "$project" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      id=$(echo "$id" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      name=$(echo "$name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      [[ -z "$name" ]] && continue
      
      # Create multiple lookup keys for different scenarios
      
      # 1. Standard pipeline name lookup (for backward compatibility)
      map_ref["$name"]="$org|$project|$id"
      
      # 2. Project-specific lookup key (for strategic initiative and potential future use)
      local project_key="${project}|${name}"
      map_ref["$project_key"]="$org|$project|$id"
      
      # Count strategic initiative entries specifically
      if [[ "$project" == "$STRATEGIC_INITIATIVE_ADO_PROJECT" ]]; then
        ((strategic_count++))
      fi
      
      ((loaded_count++))
    done
  } < "$file"
  
  log "Loaded $loaded_count pipelines from $file"
  if [ $strategic_count -gt 0 ]; then
    log "  Strategic Initiative pipelines: $strategic_count"
  fi
}

# Enhanced pipeline lookup with strategic initiative support
lookup_pipeline_info() {
  local github_org="$1"
  local pipeline_name="$2"
  local branch="$3"
  
  local found_entry=""
  local lookup_source=""
  local lookup_key=""
  
  # Special handling for strategic initiative GitHub org
  if [[ "$github_org" == "$STRATEGIC_INITIATIVE_GITHUB_ORG" ]]; then
    lookup_key="${STRATEGIC_INITIATIVE_ADO_PROJECT}|${pipeline_name}"
    
    # Try strategic initiative specific lookup first
    found_entry="${PIPELINE_LOOKUP_DEV[$lookup_key]:-}"
    [[ -n "$found_entry" ]] && lookup_source="DEV-Strategic"
    
    if [[ -z "$found_entry" ]]; then
      found_entry="${PIPELINE_LOOKUP_HE[$lookup_key]:-}"
      [[ -n "$found_entry" ]] && lookup_source="HE-Strategic"
    fi
  fi
  
  # If strategic lookup failed or not strategic initiative, try standard approach
  if [[ -z "$found_entry" ]]; then
    pipeline_cleaned=$(clean_pipeline_name "$pipeline_name")
    branch_lower=$(echo "$branch" | tr '[:upper:]' '[:lower:]')
    
    # Standard lookup logic based on branch
    if [[ "$branch_lower" == "main" ]]; then
      found_entry="${PIPELINE_LOOKUP_DEV[$pipeline_cleaned]:-}"
      [[ -n "$found_entry" ]] && lookup_source="DEV"
      [[ -z "$found_entry" ]] && found_entry="${PIPELINE_LOOKUP_DEV[$pipeline_name]:-}" && [[ -n "$found_entry" ]] && lookup_source="DEV"
    else
      found_entry="${PIPELINE_LOOKUP_HE[$pipeline_cleaned]:-}"
      [[ -n "$found_entry" ]] && lookup_source="HE"
      [[ -z "$found_entry" ]] && found_entry="${PIPELINE_LOOKUP_HE[$pipeline_name]:-}" && [[ -n "$found_entry" ]] && lookup_source="HE"
    fi
    
    # Try both DEV and HE if not found
    if [[ -z "$found_entry" ]]; then
      found_entry="${PIPELINE_LOOKUP_DEV[$pipeline_cleaned]:-}"
      [[ -n "$found_entry" ]] && lookup_source="DEV"
      [[ -z "$found_entry" ]] && found_entry="${PIPELINE_LOOKUP_HE[$pipeline_cleaned]:-}" && [[ -n "$found_entry" ]] && lookup_source="HE"
    fi
  fi
  
  # Return the result
  if [[ -n "$found_entry" ]]; then
    echo "$found_entry|$lookup_source"
  else
    echo "|not_found"
  fi
}

# Function to normalize field values for compliance checking
normalize_value() {
    local value="$1"
    # Remove quotes and whitespace, convert to lowercase
    echo "$value" | sed 's/^"//;s/"$//' | xargs | tr '[:upper:]' '[:lower:]'
}

# Function to check if value is considered "empty/NA"
is_empty_or_na() {
    local value="$1"
    local normalized=$(normalize_value "$value")
    
    if [[ "$normalized" == "" || "$normalized" == "na" || "$normalized" == "null" || "$normalized" == "none" || "$normalized" == "no" ]]; then
        return 0  # true
    else
        return 1  # false
    fi
}

# Function to check if value is considered "yes/enabled"
is_yes_or_enabled() {
    local value="$1"
    local normalized=$(normalize_value "$value")
    
    if [[ "$normalized" == "yes" || "$normalized" == "enabled" || "$normalized" == "true" || "$normalized" == "required" ]]; then
        return 0  # true
    else
        return 1  # false
    fi
}

# Function to check if PR validation contains disabled status
has_disabled_pr_validation() {
    local pr_validation="$1"
    
    # Check if any of the PR validation statuses contains "disabled"
    if [[ "$pr_validation" =~ disabled ]]; then
        return 0  # true - has disabled
    else
        return 1  # false - no disabled found
    fi
}

# Function to check compliance and add to non-compliant list
check_compliance() {
    local org="$1"
    local repo="$2"
    local branch="$3"
    local status_checks="$4"
    local contexts="$5"
    local pr_validation="$6"
    
    # Check if this repo should be ignored for non-compliance reporting
    if should_ignore_repo "$org" "$repo"; then
        log "        ⚠️  Repository ignored (found in ignore.csv)"
        return 1  # Return 1 to indicate not added to non-compliant list
    fi
    
    local is_non_compliant=false
    local reason=""
    
    # Condition 1: Status_Checks_Required is NA/No
    if is_empty_or_na "$status_checks"; then
        is_non_compliant=true
        reason="Status checks not required (NA/No)"
    
    # Condition 2 & 3: Status_Checks_Required is Yes
    elif is_yes_or_enabled "$status_checks"; then
        
        # Condition 2: Status check is Yes but Contexts is NA
        if is_empty_or_na "$contexts"; then
            is_non_compliant=true
            reason="Status checks required but no contexts configured"
        
        # Condition 3: Status check is Yes, Contexts has value, but PR validation has disabled
        elif ! is_empty_or_na "$contexts" && has_disabled_pr_validation "$pr_validation"; then
            is_non_compliant=true
            reason="Status checks and contexts configured but PR validation contains disabled"
        fi
    fi
    
    # Add to non-compliant list if conditions are met
    if [ "$is_non_compliant" = true ]; then
        local key="${org}|${repo}|${branch}"
        NON_COMPLIANT_REPOS["$key"]="$org,$repo,$branch,$status_checks,$contexts,$pr_validation"
        log "        ✗ Non-compliant: $reason"
        return 0
    else
        log "        ✓ Compliant"
        return 1
    fi
}

# Function to generate non-compliant CSV for each organization
generate_non_compliant_csv() {
    log "Generating non-compliant CSV files..."
    
    # Get unique organizations from non-compliant repos
    local orgs_with_issues=()
    for key in "${!NON_COMPLIANT_REPOS[@]}"; do
        local org=$(echo "$key" | cut -d'|' -f1)
        if [[ ! " ${orgs_with_issues[*]} " =~ " $org " ]]; then
            orgs_with_issues+=("$org")
        fi
    done
    
    # Generate CSV for each organization
    for org in "${orgs_with_issues[@]}"; do
        local output_file="non-compliant_${org}.csv"
        local count=0
        local ignored_count=0
        
        # Create CSV header with branch and owner_email columns
        echo "org,repo_name,branch,status_check,context,pr_validation,owner_email" > "$output_file"
        
        # Add non-compliant repos for this organization
        for key in "${!NON_COMPLIANT_REPOS[@]}"; do
            local repo_org=$(echo "$key" | cut -d'|' -f1)
            local repo_name=$(echo "$key" | cut -d'|' -f2)
            if [[ "$repo_org" == "$org" ]]; then
                # Double-check if repo should be ignored (safety check)
                if should_ignore_repo "$repo_org" "$repo_name"; then
                    ((ignored_count++))
                    log "    Skipping ignored repo: $repo_org/$repo_name"
                    continue
                fi
                
                # Get owner email for this repo
                local owner_email=$(get_owner_email "$repo_org" "$repo_name")
                # Append owner email to the existing CSV line
                echo "${NON_COMPLIANT_REPOS[$key]},$owner_email" >> "$output_file"
                ((count++))
            fi
        done
        
        log "✓ Generated: $output_file ($count non-compliant repositories)"
        if [ $ignored_count -gt 0 ]; then
            log "  Note: $ignored_count repositories were skipped (found in ignore.csv)"
        fi
    done
    
    # Summary
    if [ ${#orgs_with_issues[@]} -eq 0 ]; then
        log "🎉 All repositories are compliant! No non-compliant CSV files generated."
    else
        log "Non-compliance summary:"
        local total_non_compliant=0
        for key in "${!NON_COMPLIANT_REPOS[@]}"; do
            local repo_org=$(echo "$key" | cut -d'|' -f1)
            local repo_name=$(echo "$key" | cut -d'|' -f2)
            if ! should_ignore_repo "$repo_org" "$repo_name"; then
                ((total_non_compliant++))
            fi
        done
        log "  Total non-compliant entries (after ignoring): $total_non_compliant"
        log "  Organizations with issues: ${#orgs_with_issues[@]}"
        for org in "${orgs_with_issues[@]}"; do
            local org_count=0
            for key in "${!NON_COMPLIANT_REPOS[@]}"; do
                local repo_org=$(echo "$key" | cut -d'|' -f1)
                local repo_name=$(echo "$key" | cut -d'|' -f2)
                if [[ "$repo_org" == "$org" ]] && ! should_ignore_repo "$repo_org" "$repo_name"; then
                    ((org_count++))
                fi
            done
            log "    $org: $org_count repositories"
        done
    fi
}

# Check if PR validation is enabled for a pipeline
is_pr_validation_enabled() {
  local org="$1"
  local project="$2"
  local pipeline_id="$3"
  local token="$4"
 
  # Skip if no token provided
  if [[ -z "$token" ]]; then
    echo "no_token"
    return
  fi
  
  local url="https://dev.azure.com/$org/${project// /%20}/_apis/build/definitions/$pipeline_id?api-version=7.0"
  local response
  response=$(curl -s -u ":$token" "$url" 2>/dev/null)
 
  if echo "$response" | jq -e '.triggers[]? | select(.triggerType=="pullRequest")' > /dev/null 2>&1; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

# Check if GitHub repo has PR webhook configured (for standalone repos)
check_github_pr_webhook_standalone() {
  local org="$1"
  local repo="$2"
  
  local webhooks_response
  webhooks_response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/repos/$org/$repo/hooks" 2>/dev/null)
  
  # Check if any webhook has pull_request event
  local pr_webhook_found
  pr_webhook_found=$(echo "$webhooks_response" | jq -r '.[] | select(.events[]? == "pull_request") | .id' 2>/dev/null)
  
  if [[ -n "$pr_webhook_found" ]]; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

# Process standalone repo validation
process_standalone_validation() {
  local github_org="$1"
  local github_repo="$2" 
  local pipeline_name="$3"
  
  # Extract github name from pipeline pattern: pull-request-validation-<github_name>/ADO
  local github_name
  github_name=$(echo "$pipeline_name" | sed 's/pull-request-validation-\(.*\)\/ADO/\1/')
  
  # Only check GitHub PR webhook - no Azure DevOps checking needed
  local webhook_status
  webhook_status=$(check_github_pr_webhook_standalone "$github_org" "$github_repo")
  
  # Return only enabled or disabled
  echo "$webhook_status"
}

# Get branch protection details for a specific branch
get_branch_protection_details() {
  local org="$1"
  local repo="$2"
  local branch="$3"
  
  local protection
  protection=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/repos/$org/$repo/branches/$branch/protection" 2>/dev/null)
  
  # Check if protection is enabled
  if [[ $(echo "$protection" | jq -r '.message' 2>/dev/null) == "Branch not protected" ]]; then
    echo "NA|NA|NA"
    return
  fi
  
  local required=$(echo "$protection" | jq -r '.required_status_checks != null' 2>/dev/null)
  local required_status=$( [[ "$required" == "true" ]] && echo "YES" || echo "NO" )
  local contexts=$(echo "$protection" | jq -r '.required_status_checks.contexts // [] | join(";")' 2>/dev/null)
  
  # If no contexts or empty contexts, mark as NA
  if [[ -z "$contexts" || "$contexts" == "[]" ]]; then
    contexts="NA"
  fi
  
  local pr_statuses="NA"
  if [[ "$contexts" != "NA" && -n "$contexts" ]]; then
    pr_statuses=""
    IFS=';' read -ra pipelines <<< "$contexts"
    for pipeline in "${pipelines[@]}"; do
      [[ -z "$pipeline" ]] && continue
      
      # Check if this is a standalone repo pattern
      if [[ "$pipeline" =~ ^pull-request-validation-.*\/ADO$ ]]; then
        pr_status=$(process_standalone_validation "$org" "$repo" "$pipeline")
      else
        # Regular pipeline processing with enhanced lookup
        pipeline_cleaned=$(clean_pipeline_name "$pipeline")
        
        # Use enhanced lookup function
        local lookup_result=$(lookup_pipeline_info "$org" "$pipeline_cleaned" "$branch")
        local found_entry=$(echo "$lookup_result" | cut -d'|' -f1-3)
        local lookup_source=$(echo "$lookup_result" | cut -d'|' -f4)
        
        if [[ -n "$found_entry" && "$lookup_source" != "not_found" ]]; then
          IFS='|' read org_ado project pipeline_id <<< "$found_entry"
          token=$( [[ "$org_ado" == "TDL-TCP-DEV" ]] && echo "$AZDO_PAT_DEV" || echo "$AZDO_PAT_HE" )
          pr_status=$(is_pr_validation_enabled "$org_ado" "$project" "$pipeline_id" "$token")
        else
          pr_status="not_found"
        fi
      fi
      pr_statuses+="$pr_status;"
    done
    pr_statuses="${pr_statuses%;}"
  fi
  
  echo "$required_status|$contexts|$pr_statuses"
}

# Process a single organization
process_organization() {
  local org="$1"
  local output_file="output_${org}.csv"
  
  log "Processing GitHub Org: $org"
  log "Output file: $output_file"
  
  if [[ "$org" == "$STRATEGIC_INITIATIVE_GITHUB_ORG" ]]; then
    log "🎯 Strategic Initiative organization detected"
    log "   Will use project-specific lookup: $STRATEGIC_INITIATIVE_ADO_PROJECT"
  fi
  
  # Create CSV header for this organization
  echo "GitHub_Org,Repository,Branch,Status_Checks_Required,Contexts,PR_Validation_Status" > "$output_file"
  
  local page=1
  while :; do
    repos=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/orgs/$org/repos?per_page=100&page=$page")
    repo_names=$(echo "$repos" | jq -r '.[].name')
    [[ -z "$repo_names" ]] && break
 
    for repo in $repo_names; do
      log "  Repo: $repo"
      
      # Get protected branches using the new API
      log "    Fetching protected branches..."
      protected_branches=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/repos/$org/$repo/branches?protected=true" 2>/dev/null)
      
      # Check if API call was successful
      if [[ $(echo "$protected_branches" | jq -r 'type' 2>/dev/null) != "array" ]]; then
        log "    Error fetching protected branches for $repo or no protected branches found"
        # Mark all target branches as NA since no protection is enabled
        for target_branch in "main" "staging" "release"; do
          log "    Branch: $target_branch - NA (no protection enabled)"
          echo "$org,$repo,$target_branch,NA,NA,NA" >> "$output_file"
          # Check compliance for NA entries
          check_compliance "$org" "$repo" "$target_branch" "NA" "NA" "NA"
        done
        continue
      fi
      
      # Get protected branch names
      local protected_branch_names
      protected_branch_names=$(echo "$protected_branches" | jq -r '.[].name' 2>/dev/null)
      
      # Check if we got any protected branches
      if [[ -z "$protected_branch_names" ]]; then
        log "    No protected branches found for repository $repo"
        # Mark all target branches as NA
        for target_branch in "main" "staging" "release"; do
          log "    Branch: $target_branch - NA (no protection enabled)"
          echo "$org,$repo,$target_branch,NA,NA,NA" >> "$output_file"
          # Check compliance for NA entries
          check_compliance "$org" "$repo" "$target_branch" "NA" "NA" "NA"
        done
        continue
      fi
      
      # Track which target branches were found with protection
      local found_target_branches=()
      local target_branches=("main" "staging" "release")
      
      # Process each protected branch
      for branch in $protected_branch_names; do
        branch_lower=$(echo "$branch" | tr '[:upper:]' '[:lower:]')
        
        # Only process target branches (main, staging, release)
        if [[ "$branch_lower" =~ $target_branches_regex ]]; then
          found_target_branches+=("$branch_lower")
          log "    Processing protected branch: $branch"
          
          # Get detailed protection information
          local protection_details=$(get_branch_protection_details "$org" "$repo" "$branch")
          local status_required=$(echo "$protection_details" | cut -d'|' -f1)
          local contexts=$(echo "$protection_details" | cut -d'|' -f2)
          local pr_statuses=$(echo "$protection_details" | cut -d'|' -f3)
          
          # Write to CSV with proper formatting
          if [[ "$status_required" == "NA" ]]; then
            echo "$org,$repo,$branch,NA,NA,NA" >> "$output_file"
            # Check compliance
            check_compliance "$org" "$repo" "$branch" "NA" "NA" "NA"
          else
            if [[ "$contexts" == "NA" ]]; then
              echo "$org,$repo,$branch,$status_required,NA,NA" >> "$output_file"
              # Check compliance
              check_compliance "$org" "$repo" "$branch" "$status_required" "NA" "NA"
            else
              echo "$org,$repo,$branch,$status_required,\"$contexts\",\"$pr_statuses\"" >> "$output_file"
              # Check compliance
              check_compliance "$org" "$repo" "$branch" "$status_required" "$contexts" "$pr_statuses"
            fi
          fi
        else
          log "    Skipping non-target protected branch: $branch"
        fi
      done
      
      # Check for missing target branches and mark them as NA
      for target_branch in "${target_branches[@]}"; do
        if [[ ! " ${found_target_branches[*]} " =~ " ${target_branch} " ]]; then
          log "    Branch: $target_branch - NA (no protection enabled)"
          echo "$org,$repo,$target_branch,NA,NA,NA" >> "$output_file"
          # Check compliance for missing branches
          check_compliance "$org" "$repo" "$target_branch" "NA" "NA" "NA"
        fi
      done
    done
    ((page++))
  done
  
  log "✓ Completed processing organization: $org"
  log "✓ Results saved to: $output_file"
}

# Select organizations function
# Select organizations function
select_organizations() {
  log "Fetching available GitHub organizations..."
  
  local orgs_response
  orgs_response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/user/orgs")
  
  # Debug: Show what we received
  log "Debug: API response preview: ${orgs_response:0:100}..."
  
  # Check if response is empty
  if [[ -z "$orgs_response" ]]; then
    log "Error: Empty response from GitHub API"
    exit 1
  fi
  
  # Check if response contains error message
  if echo "$orgs_response" | jq -e '.message' >/dev/null 2>&1; then
    local error_msg=$(echo "$orgs_response" | jq -r '.message')
    log "Error from GitHub API: $error_msg"
    exit 1
  fi
  
  # Check if response is a valid array
  if ! echo "$orgs_response" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log "Error: Invalid response format from GitHub API"
    log "Response type: $(echo "$orgs_response" | jq -r 'type' 2>/dev/null || echo "invalid JSON")"
    log "Full response: $orgs_response"
    exit 1
  fi
  
  local orgs
  orgs=$(echo "$orgs_response" | jq -r '.[].login')
  
  if [[ -z "$orgs" ]]; then
    log "No organizations found or accessible with the provided token"
    exit 1
  fi
  
  # Rest of the function remains the same...
  
  local org_array=()
  while IFS= read -r org; do
    org_array+=("$org")
  done <<< "$orgs"
  
  echo ""
  echo "Available GitHub Organizations:"
  echo "==============================="
  for i in "${!org_array[@]}"; do
    printf "%2d. %s" $((i+1)) "${org_array[$i]}"
   
    if [[ "${org_array[$i]}" == "$STRATEGIC_INITIATIVE_GITHUB_ORG" ]]; then
      printf " 🎯 (Strategic Initiative - Special Mapping Enabled)"
    fi
    printf "\n"
  done
  echo ""
  printf "%2s. %s\n" "A" "All organizations"
  echo ""
  
  local selected_orgs=()
  while true; do
    echo "Please select organization(s) to process:"
    echo "• Enter a number (1-${#org_array[@]}) for a specific organization"
    echo "• Enter 'A' or 'a' to process all organizations"
    echo "• Enter multiple numbers separated by spaces (e.g., '1 3 5')"
    echo "• Enter 'q' to quit"
    echo ""
    read -p "Your selection: " selection
    
    if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
      log "Exiting..."
      exit 0
    fi
    
    if [[ "$selection" == "a" || "$selection" == "A" ]]; then
      selected_orgs=("${org_array[@]}")
      log "Selected: All organizations (${#selected_orgs[@]} total)"
      break
    fi
    
    selected_orgs=()
    local valid_selection=true
    
    for num in $selection; do
      if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#org_array[@]} )); then
        selected_orgs+=("${org_array[$((num-1))]}")
      else
        echo "Invalid selection: $num (must be between 1 and ${#org_array[@]})"
        valid_selection=false
        break
      fi
    done
    
    if [[ "$valid_selection" == true ]] && [[ ${#selected_orgs[@]} -gt 0 ]]; then
      log "Selected organizations:"
      for org in "${selected_orgs[@]}"; do
        if [[ "$org" == "$STRATEGIC_INITIATIVE_GITHUB_ORG" ]]; then
          log "  $org 🎯 (Strategic Initiative - Special Mapping)"
        else
          log "  $org"
        fi
      done
      break
    fi
    
    echo ""
  done
  
  echo ""
  SELECTED_ORGS=("${selected_orgs[@]}")
}

# --- MAIN EXECUTION ---
log "GitHub Azure DevOps Pipeline Validation Report Generator with Azure Key Vault Integration"

# Check for required tools
if ! command -v jq &> /dev/null; then
  log "Error: jq is required but not installed"
  log "Install with: brew install jq (macOS) or apt install jq (Ubuntu)"
  exit 1
fi

# Step 1: Load tokens from Azure Key Vault
load_tokens_from_akv

# Step 2: Load ignore list
log "Loading ignore list..."
load_ignore_to_lookup

# Step 3: Organization Selection
select_organizations

# Step 4: Load pipeline data with enhanced key structure
log "Loading pipeline data with enhanced lookup..."
load_csv_to_lookup "$CSV_DEV" PIPELINE_LOOKUP_DEV
load_csv_to_lookup "$CSV_HE" PIPELINE_LOOKUP_HE
 
log "Pipeline lookup summary:"
log "  DEV pipelines: ${#PIPELINE_LOOKUP_DEV[@]}"
log "  HE pipelines: ${#PIPELINE_LOOKUP_HE[@]}"
log "  Standalone repos: webhook-only checking (no CSV mapping required)"
log "  Ignored repositories: ${#IGNORE_LOOKUP[@]}"
log "  Strategic Initiative mapping: $STRATEGIC_INITIATIVE_GITHUB_ORG -> $STRATEGIC_INITIATIVE_ADO_PROJECT"

# Step 5: Process selected organizations
log "Starting processing for ${#SELECTED_ORGS[@]} organization(s)..."
for org in "${SELECTED_ORGS[@]}"; do
  log "======================================"
  log "Processing Organization: $org"
  log "======================================"
  
  # Load owners data for this organization
  load_owners_to_lookup "$org"
  
  # Process the organization
  process_organization "$org"
done

# Step 6: Generate non-compliant CSV files
generate_non_compliant_csv

log "======================================"
log "PROCESSING COMPLETE"
log "======================================"
log "Output files generated:"
for org in "${SELECTED_ORGS[@]}"; do
  log "  Main report: output_${org}.csv"
done
log "  Non-compliant reports: non-compliant_{org_name}.csv"
log "Summary: Processed ${#SELECTED_ORGS[@]} organization(s) successfully"
