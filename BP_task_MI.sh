#!/usr/bin/env bash

# ============================================================================
# GitHub Azure DevOps Pipeline Validation Report Generator
# Enhanced with: Dual Branch Protection, Checkmarx Detection, Azure MI
# ============================================================================

# --- CONFIGURATION ---
GITHUB_API="https://api.github.com"

# Azure Key Vault Configuration
KEY_VAULT_NAME="akv-tdsif-sif-ci-sec-01"
GITHUB_TOKEN_SECRET_NAME="githubpat"
AZDO_PAT_DEV_SECRET_NAME="azdo-pat-dev"
AZDO_PAT_HE_SECRET_NAME="azdo-pat-he"

# Initialize token variables
GITHUB_TOKEN=""
AZDO_PAT_DEV=""
AZDO_PAT_HE=""

# Other configurations
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

declare -A PIPELINE_LOOKUP_DEV
declare -A PIPELINE_LOOKUP_HE
declare -A NON_COMPLIANT_REPOS
declare -A OWNERS_LOOKUP
declare -A IGNORE_LOOKUP

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Logging function with IST time - logs to stderr to avoid CSV contamination
log() {
  local ist_time=$(TZ='Asia/Kolkata' date +"%Y-%m-%d %H:%M:%S IST")
  echo "[$ist_time] $*" >&2
}

# Pipeline name cleaning
clean_pipeline_name() {
  local name="$1"
  echo "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//; s/"$//'
}

# ============================================================================
# AZURE MANAGED IDENTITY & KEY VAULT FUNCTIONS
# ============================================================================

# Get access token using VM Managed Identity
get_managed_identity_token() {
  local resource="$1"
  
  log "Getting access token for resource: $resource"
  
  local imds_endpoint="http://169.254.169.254/metadata/identity/oauth2/token"
  local token_response=$(curl -s -H "Metadata: true" \
    "${imds_endpoint}?api-version=2018-02-01&resource=${resource}" 2>/dev/null)
  
  if [[ $? -ne 0 ]] || [[ -z "$token_response" ]]; then
    log "Error: Failed to get managed identity token"
    return 1
  fi
  
  local access_token=$(echo "$token_response" | jq -r '.access_token' 2>/dev/null)
  
  if [[ -z "$access_token" ]] || [[ "$access_token" == "null" ]]; then
    log "Error: Invalid token response from managed identity"
    return 1
  fi
  
  echo "$access_token"
}

# Check if running on Azure VM with managed identity
check_managed_identity() {
  log "Checking for Azure VM Managed Identity..."
  
  if ! curl -s -m 5 -H "Metadata: true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net/" \
    >/dev/null 2>&1; then
    log "Error: Azure Instance Metadata Service not accessible"
    log "This script requires Azure VM with Managed Identity enabled"
    exit 1
  fi
  
  log "✓ Azure VM Managed Identity detected"
}

# Fetch secret from Azure Key Vault using managed identity
get_secret_from_akv_with_managed_identity() {
  local secret_name="$1"
  
  log "Fetching secret '$secret_name' using managed identity..."
  
  local access_token=$(get_managed_identity_token "https://vault.azure.net/")
  if [[ $? -ne 0 ]] || [[ -z "$access_token" ]]; then
    log "Error: Failed to get Key Vault access token"
    exit 1
  fi
  
  local vault_url="https://${KEY_VAULT_NAME}.vault.azure.net/secrets/${secret_name}?api-version=7.4"
  local secret_response=$(curl -s -H "Authorization: Bearer $access_token" "$vault_url" 2>/dev/null)
  
  if [[ $? -ne 0 ]] || [[ -z "$secret_response" ]]; then
    log "Error: Failed to fetch secret '$secret_name'"
    exit 1
  fi
  
  if echo "$secret_response" | jq -e '.error' >/dev/null 2>&1; then
    local error_msg=$(echo "$secret_response" | jq -r '.error.message // .error')
    log "Error fetching secret '$secret_name': $error_msg"
    exit 1
  fi
  
  local secret_value=$(echo "$secret_response" | jq -r '.value' 2>/dev/null)
  
  if [[ -z "$secret_value" ]] || [[ "$secret_value" == "null" ]]; then
    log "Error: Invalid secret value for '$secret_name'"
    exit 1
  fi
  
  echo "$secret_value"
}

# Check if secret exists in Key Vault
secret_exists_in_akv() {
  local secret_name="$1"
  
  local access_token=$(get_managed_identity_token "https://vault.azure.net/")
  if [[ $? -ne 0 ]] || [[ -z "$access_token" ]]; then
    return 1
  fi
  
  local vault_url="https://${KEY_VAULT_NAME}.vault.azure.net/secrets/${secret_name}?api-version=7.4"
  local response=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $access_token" "$vault_url" -o /dev/null 2>/dev/null)
  
  [[ "$response" == "200" ]]
}

# Load all tokens from Azure Key Vault using managed identity
load_tokens_from_akv_managed_identity() {
  log "Loading tokens from Azure Key Vault using Managed Identity..."
  
  check_managed_identity
  
  GITHUB_TOKEN=$(get_secret_from_akv_with_managed_identity "$GITHUB_TOKEN_SECRET_NAME")
  
  if secret_exists_in_akv "$AZDO_PAT_DEV_SECRET_NAME"; then
    AZDO_PAT_DEV=$(get_secret_from_akv_with_managed_identity "$AZDO_PAT_DEV_SECRET_NAME")
  else
    log "Warning: Azure DevOps DEV token not found in Key Vault"
  fi
  
  if secret_exists_in_akv "$AZDO_PAT_HE_SECRET_NAME"; then
    AZDO_PAT_HE=$(get_secret_from_akv_with_managed_identity "$AZDO_PAT_HE_SECRET_NAME")
  else
    log "Warning: Azure DevOps HE token not found in Key Vault"
  fi
  
  if [[ -z "$GITHUB_TOKEN" ]]; then
    log "Error: GitHub token is required but not available"
    exit 1
  fi
  
  log "✓ Tokens loaded successfully using Managed Identity"
  log "  GitHub Token: ${GITHUB_TOKEN:0:7}... (${#GITHUB_TOKEN} chars)"
  [[ -n "$AZDO_PAT_DEV" ]] && log "  Azure DevOps DEV Token: Available"
  [[ -n "$AZDO_PAT_HE" ]] && log "  Azure DevOps HE Token: Available"
}

# ============================================================================
# CSV LOADING FUNCTIONS
# ============================================================================

# Load ignore CSV to lookup hash map
load_ignore_to_lookup() {
  local ignore_file="$IGNORE_CSV"
  
  unset IGNORE_LOOKUP
  declare -gA IGNORE_LOOKUP
  
  if [[ ! -f "$ignore_file" ]]; then
    log "Warning: Ignore file not found: $ignore_file"
    return 0
  fi
 
  log "Loading ignore CSV: $ignore_file"
  local loaded_count=0
  
  {
    read first_line
    if [[ "$first_line" =~ ^[[:space:]]*[Oo]rg[[:space:]]*,[[:space:]]*[Rr]epo ]]; then
      log "Skipping header line"
    else
      IFS=',' read -r org_name repo_name rest <<< "$first_line"
      org_name=$(echo "$org_name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      repo_name=$(echo "$repo_name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      
      if [[ -n "$org_name" && -n "$repo_name" ]]; then
        IGNORE_LOOKUP["${org_name}|${repo_name}"]="true"
        ((loaded_count++))
      fi
    fi
    
    while IFS=',' read -r org_name repo_name rest; do
      [[ -z "$org_name" && -z "$repo_name" ]] && continue
      
      org_name=$(echo "$org_name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      repo_name=$(echo "$repo_name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      
      [[ -z "$org_name" || -z "$repo_name" ]] && continue
      
      IGNORE_LOOKUP["${org_name}|${repo_name}"]="true"
      ((loaded_count++))
    done
  } < "$ignore_file" 2>/dev/null
  
  log "Loaded $loaded_count ignore entries"
}

# Check if repository should be ignored
should_ignore_repo() {
  local org="$1"
  local repo="$2"
  [[ -n "${IGNORE_LOOKUP["${org}|${repo}"]:-}" ]]
}

# Load owners CSV to lookup hash map
load_owners_to_lookup() {
  local org="$1"
  local csv_file="$OWNERS_DIR/git_owners_${org}.csv"
  
  for key in "${!OWNERS_LOOKUP[@]}"; do
    if [[ "$key" =~ ^${org}\| ]]; then
      unset OWNERS_LOOKUP["$key"]
    fi
  done
  
  if [[ ! -f "$csv_file" ]]; then
    log "Warning: Owners file not found: $csv_file"
    return 0
  fi
 
  log "Loading owners CSV: $csv_file"
  local loaded_count=0
  
  {
    read # skip header
    while IFS=',' read -r repo_name repo_owner rest; do
      [[ -z "$repo_name" && -z "$repo_owner" ]] && continue
      
      repo_name=$(echo "$repo_name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      repo_owner=$(echo "$repo_owner" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      
      [[ -z "$repo_name" || -z "$repo_owner" ]] && continue
      
      OWNERS_LOOKUP["${org}|${repo_name}"]="$repo_owner"
      ((loaded_count++))
    done
  } < "$csv_file" 2>/dev/null
  
  log "Loaded $loaded_count owner mappings"
}

# Get owner email for a repository
get_owner_email() {
  local org="$1"
  local repo="$2"
  local email="${OWNERS_LOOKUP["${org}|${repo}"]:-}"
  echo "${email:-no-owner@unknown.com}"
}

# Load CSV to lookup hash map
load_csv_to_lookup() {
  local file="$1"
  local -n map_ref=$2
 
  if [[ ! -f "$file" ]]; then
    log "Warning: CSV file not found: $file"
    return 0
  fi
 
  log "Loading CSV: $file"
  local loaded_count=0
  
  {
    read # skip header
    while IFS=',' read -r org project id name rest; do
      [[ -z "$org" && -z "$project" && -z "$id" && -z "$name" ]] && continue
      [[ -z "$org" || -z "$project" || -z "$id" || -z "$name" ]] && continue
      
      org=$(echo "$org" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      project=$(echo "$project" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      id=$(echo "$id" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      name=$(echo "$name" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      [[ -z "$name" ]] && continue
      
      map_ref["$name"]="$org|$project|$id"
      map_ref["${project}|${name}"]="$org|$project|$id"
      
      ((loaded_count++))
    done
  } < "$file" 2>/dev/null
  
  log "Loaded $loaded_count pipelines from $file"
}

# ============================================================================
# PIPELINE LOOKUP FUNCTIONS
# ============================================================================

# Enhanced pipeline lookup with strategic initiative support
lookup_pipeline_info() {
  local github_org="$1"
  local pipeline_name="$2"
  local branch="$3"
  
  local found_entry=""
  local lookup_source=""
  
  if [[ "$github_org" == "$STRATEGIC_INITIATIVE_GITHUB_ORG" ]]; then
    local lookup_key="${STRATEGIC_INITIATIVE_ADO_PROJECT}|${pipeline_name}"
    
    found_entry="${PIPELINE_LOOKUP_DEV[$lookup_key]:-}"
    [[ -n "$found_entry" ]] && lookup_source="DEV-Strategic"
    
    if [[ -z "$found_entry" ]]; then
      found_entry="${PIPELINE_LOOKUP_HE[$lookup_key]:-}"
      [[ -n "$found_entry" ]] && lookup_source="HE-Strategic"
    fi
  fi
  
  if [[ -z "$found_entry" ]]; then
    local pipeline_cleaned=$(clean_pipeline_name "$pipeline_name")
    local branch_lower=$(echo "$branch" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$branch_lower" == "main" ]]; then
      found_entry="${PIPELINE_LOOKUP_DEV[$pipeline_cleaned]:-}"
      [[ -n "$found_entry" ]] && lookup_source="DEV"
    else
      found_entry="${PIPELINE_LOOKUP_HE[$pipeline_cleaned]:-}"
      [[ -n "$found_entry" ]] && lookup_source="HE"
    fi
    
    if [[ -z "$found_entry" ]]; then
      found_entry="${PIPELINE_LOOKUP_DEV[$pipeline_cleaned]:-}"
      [[ -n "$found_entry" ]] && lookup_source="DEV"
      [[ -z "$found_entry" ]] && found_entry="${PIPELINE_LOOKUP_HE[$pipeline_cleaned]:-}" && [[ -n "$found_entry" ]] && lookup_source="HE"
    fi
  fi
  
  if [[ -n "$found_entry" ]]; then
    echo "$found_entry|$lookup_source"
  else
    echo "|not_found"
  fi
}

# ============================================================================
# COMPLIANCE CHECKING FUNCTIONS
# ============================================================================

# Check if PR validation contains disabled status
has_disabled_pr_validation() {
    local pr_validation="$1"
    [[ "$pr_validation" =~ disabled ]]
}

# Check if Checkmarx status is disabled or no
has_disabled_or_no_checkmarx() {
    local checkmarx_status="$1"
    [[ "$checkmarx_status" == "disabled" || "$checkmarx_status" == "no" ]]
}

# Check compliance and add to non-compliant list
check_compliance() {
    local org="$1" 
    local repo="$2" 
    local branch="$3" 
    local status_checks="$4" 
    local contexts="$5" 
    local pr_validation="$6"
    local checkmarx_status="$7"
    
    if should_ignore_repo "$org" "$repo"; then
        log "        ⚠️  Repository ignored"
        return 1
    fi
    
    local is_non_compliant=false
    local reason=""
    
    # Condition 1: Status_Checks_Required is no
    if [[ "$status_checks" == "no" ]]; then
        is_non_compliant=true
        reason="Status checks not required"
    
    # Conditions when Status_Checks_Required is yes
    elif [[ "$status_checks" == "yes" ]]; then
        
        # Condition 2: Status check is yes but Contexts is no
        if [[ "$contexts" == "no" ]]; then
            is_non_compliant=true
            reason="Status checks required but no contexts configured"
        
        # Condition 3: Contexts configured but PR validation disabled
        elif [[ "$contexts" != "no" ]] && has_disabled_pr_validation "$pr_validation"; then
            is_non_compliant=true
            reason="PR validation contains disabled status"
        
        # Condition 4: PR validation enabled but Checkmarx disabled/no
        elif [[ "$contexts" != "no" ]] && ! has_disabled_pr_validation "$pr_validation" && has_disabled_or_no_checkmarx "$checkmarx_status"; then
            is_non_compliant=true
            reason="PR validation enabled but Checkmarx is disabled or not configured"
        fi
    fi
    
    if [ "$is_non_compliant" = true ]; then
        NON_COMPLIANT_REPOS["${org}|${repo}|${branch}"]="$org,$repo,$branch,$status_checks,$contexts,$pr_validation,$checkmarx_status"
        log "        ✗ Non-compliant: $reason"
        return 0
    else
        log "        ✓ Compliant"
        return 1
    fi
}

# Generate non-compliant CSV
generate_non_compliant_csv() {
    log "Generating non-compliant CSV files..."
    
    local orgs_with_issues=()
    for key in "${!NON_COMPLIANT_REPOS[@]}"; do
        local org=$(echo "$key" | cut -d'|' -f1)
        if [[ ! " ${orgs_with_issues[*]} " =~ " $org " ]]; then
            orgs_with_issues+=("$org")
        fi
    done
    
    for org in "${orgs_with_issues[@]}"; do
        local output_file="non-compliant_${org}.csv"
        local count=0
        
        echo "org,repo_name,branch,status_check,context,pr_validation,checkmarx_status,owner_email" > "$output_file"
        
        for key in "${!NON_COMPLIANT_REPOS[@]}"; do
            local repo_org=$(echo "$key" | cut -d'|' -f1)
            local repo_name=$(echo "$key" | cut -d'|' -f2)
            
            if [[ "$repo_org" == "$org" ]]; then
                if should_ignore_repo "$repo_org" "$repo_name"; then
                    continue
                fi
                
                local owner_email=$(get_owner_email "$repo_org" "$repo_name")
                echo "${NON_COMPLIANT_REPOS[$key]},$owner_email" >> "$output_file"
                ((count++))
            fi
        done
        
        log "✓ Generated: $output_file ($count entries)"
    done
    
    if [ ${#orgs_with_issues[@]} -eq 0 ]; then
        log "🎉 All repositories are compliant!"
    fi
}

# ============================================================================
# AZURE DEVOPS VALIDATION FUNCTIONS
# ============================================================================

# Check if PR validation is enabled for a pipeline
is_pr_validation_enabled() {
  local org="$1" project="$2" pipeline_id="$3" token="$4"
  
  [[ -z "$token" ]] && { echo "no_token"; return; }
  
  local url="https://dev.azure.com/$org/${project// /%20}/_apis/build/definitions/$pipeline_id?api-version=7.0"
  local response=$(curl -s -u ":$token" "$url" 2>/dev/null)
 
  if echo "$response" | jq -e '.triggers[]? | select(.triggerType=="pullRequest")' >/dev/null 2>&1; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

# Check if pipeline has Checkmarx tasks
check_checkmarx_in_pipeline() {
    local org="$1"
    local project="$2" 
    local pipeline_id="$3"
    local token="$4"
    
    if [[ -z "$token" ]]; then
        echo "no_token|"
        return
    fi
    
    local encoded_project=$(echo "$project" | sed 's/ /%20/g')
    local url="https://dev.azure.com/$org/$encoded_project/_apis/build/definitions/$pipeline_id?api-version=7.0"
    local response=$(curl -s -u ":$token" "$url" 2>/dev/null)
    
    if [[ -z "$response" ]] || echo "$response" | jq -e '.message' >/dev/null 2>&1; then
        echo "api_error|"
        return
    fi
    
    local ptype=$(echo "$response" | jq -r '.process.type // "unknown"')
    
    if [[ "$ptype" == "1" ]]; then
        analyze_classic_pipeline "$response"
    elif [[ "$ptype" == "2" ]]; then
        analyze_yaml_pipeline_integrated "$response"
    else
        echo "unknown_pipeline_type|"
    fi
}

# Analyze classic/designer pipeline for Checkmarx
analyze_classic_pipeline() {
    local response="$1"
    
    local direct_enabled=$(echo "$response" | jq -r '
        [.process.phases[]?.steps[]? | 
         select(.task.id == "dd862edc-5d88-4d2c-b83b-fff2a695e5c0" and .enabled == true)] | length' 2>/dev/null || echo "0")
    
    local direct_disabled=$(echo "$response" | jq -r '
        [.process.phases[]?.steps[]? | 
         select(.task.id == "dd862edc-5d88-4d2c-b83b-fff2a695e5c0" and .enabled == false)] | length' 2>/dev/null || echo "0")
    
    local taskgroup_enabled=$(echo "$response" | jq -r '
        [.process.phases[]?.steps[]? | 
         select(.task.definitionType == "metaTask" and 
                (.displayName | test("(?i)checkmarx")) and .enabled == true)] | length' 2>/dev/null || echo "0")
    
    local taskgroup_disabled=$(echo "$response" | jq -r '
        [.process.phases[]?.steps[]? | 
         select(.task.definitionType == "metaTask" and 
                (.displayName | test("(?i)checkmarx")) and .enabled == false)] | length' 2>/dev/null || echo "0")
    
    local disabled_tasks=$(echo "$response" | jq -r '
        [.process.phases[]?.steps[]? | 
         select((.task.id == "dd862edc-5d88-4d2c-b83b-fff2a695e5c0" or 
                (.task.definitionType == "metaTask" and (.displayName | test("(?i)checkmarx")))) 
                and .enabled == false) | .displayName] | join("; ")' 2>/dev/null || echo "")
    
    local total_enabled=$((direct_enabled + taskgroup_enabled))
    local total_disabled=$((direct_disabled + taskgroup_disabled))
    local total_checkmarx=$((total_enabled + total_disabled))
    
    # If ANY Checkmarx task is disabled, overall status = disabled
    if [[ $total_checkmarx -eq 0 ]]; then
        echo "enabled|no_checkmarx"
    elif [[ $total_disabled -gt 0 ]]; then
        echo "disabled|$disabled_tasks"
    else
        echo "enabled|"
    fi
}

# Analyze YAML pipeline for Checkmarx
analyze_yaml_pipeline_integrated() {
    local response="$1"
    
    local yaml_path=$(echo "$response" | jq -r '.process.yamlFilename // "unknown"')
    local repo=$(echo "$response" | jq -r '.repository.properties.fullName // "unknown"')
    local branch=$(echo "$response" | jq -r '.repository.defaultBranch // "main"' | sed 's#refs/heads/##')
    
    if [[ "$yaml_path" == "unknown" || "$repo" == "unknown" ]]; then
        echo "enabled|yaml_error"
        return
    fi
    
    local github_url="https://api.github.com/repos/$repo/contents/$yaml_path?ref=$branch"
    local github_resp=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$github_url" 2>/dev/null)
    
    if echo "$github_resp" | jq -e '.message' >/dev/null 2>&1; then
        echo "enabled|yaml_fetch_error"
        return
    fi
    
    local yaml_content=$(echo "$github_resp" | jq -r '.content' | base64 -d 2>/dev/null)
    
    if [[ -z "$yaml_content" ]]; then
        echo "enabled|yaml_decode_error"
        return
    fi
    
    if echo "$yaml_content" | grep -qi "checkmarx"; then
        local disabled_conditions=$(echo "$yaml_content" | grep -B5 -A5 -i "checkmarx" | grep -i "condition.*false\|enabled.*false" || echo "")
        if [[ -n "$disabled_conditions" ]]; then
            echo "disabled|YAML - some Checkmarx tasks disabled"
        else
            echo "enabled|"
        fi
    else
        echo "enabled|no_checkmarx"
    fi
}

# ============================================================================
# GITHUB VALIDATION FUNCTIONS
# ============================================================================

# GitHub webhook validation
check_github_pr_webhook_standalone() {
  local org="$1" repo="$2"
  
  local webhooks_response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/repos/$org/$repo/hooks" 2>/dev/null)
  local pr_webhook_found=$(echo "$webhooks_response" | jq -r '.[] | select(.events[]? == "pull_request") | .id' 2>/dev/null)
  
  [[ -n "$pr_webhook_found" ]] && echo "enabled" || echo "disabled"
}

# Process standalone repo validation
process_standalone_validation() {
  local github_org="$1" github_repo="$2" pipeline_name="$3"
  check_github_pr_webhook_standalone "$github_org" "$github_repo"
}

# Enhanced branch protection check using both Classic and Ruleset APIs
get_branch_protection_details() {
  local org="$1" repo="$2" branch="$3"
  
  log "      Checking protection for branch: $branch"
  
  local protection_source="none"
  local contexts=""
  local status_enabled="false"
  local pr_statuses="disabled"
  local checkmarx_statuses="enabled"
  local checkmarx_details="no_checkmarx"
  
  # Step 1: Check Classic Branch Protection API
  log "        Checking Classic branch protection..."
  local classic_protection
  classic_protection=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/repos/$org/$repo/branches/$branch/protection" 2>/dev/null)
  
  if [[ $(echo "$classic_protection" | jq -r '.message' 2>/dev/null) != "Branch not protected" ]] && [[ -n "$classic_protection" ]]; then
    local classic_contexts=$(echo "$classic_protection" | jq -r '.required_status_checks.contexts // [] | join("|")' 2>/dev/null)
    if [[ -n "$classic_contexts" && "$classic_contexts" != "" ]]; then
      protection_source="classic"
      contexts="$classic_contexts"
      status_enabled="true"
      log "        ✓ Classic protection found with contexts"
    else
      log "        ○ Classic protection exists but no status check contexts"
    fi
  else
    log "        ○ No classic branch protection found"
  fi
  
  # Step 2: Check Rulesets API if classic didn't provide contexts
  if [[ "$status_enabled" == "false" ]]; then
    log "        Checking Repository Rulesets..."
    local rulesets_response
    rulesets_response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/repos/$org/$repo/rulesets" 2>/dev/null)
    
    if [[ $(echo "$rulesets_response" | jq -r 'type' 2>/dev/null) == "array" ]]; then
      local ruleset_ids=$(echo "$rulesets_response" | jq -r '.[] | select(.target=="branch") | .id' 2>/dev/null)
      
      for rule_id in $ruleset_ids; do
        if [[ -n "$rule_id" && "$rule_id" != "null" ]]; then
          log "          Checking ruleset ID: $rule_id"
          local ruleset_detail
          ruleset_detail=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/repos/$org/$repo/rulesets/$rule_id" 2>/dev/null)
          
          local branch_match=$(echo "$ruleset_detail" | jq -r --arg branch "refs/heads/$branch" \
            '.conditions.ref_name.include // [] | .[] | select(.==$branch or .=="refs/heads/*" or .=="*")' 2>/dev/null)
          
          if [[ -n "$branch_match" ]]; then
            log "            ✓ Ruleset applies to branch: $branch"
            local ruleset_contexts=$(echo "$ruleset_detail" | jq -r \
              '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks // [] | .[] | .context // empty' 2>/dev/null | paste -sd "|" -)
            
            if [[ -n "$ruleset_contexts" && "$ruleset_contexts" != "" ]]; then
              protection_source="ruleset"
              contexts="$ruleset_contexts"
              status_enabled="true"
              log "            ✓ Ruleset protection found with contexts"
              break
            else
              log "            ○ Ruleset applies but no status check contexts found"
            fi
          else
            log "            ○ Ruleset doesn't apply to branch: $branch"
          fi
        fi
      done
    else
      log "        ○ No rulesets found or API error"
    fi
  fi
  
  # Step 3: Process contexts and get pipeline statuses if any contexts found
  if [[ "$status_enabled" == "true" && -n "$contexts" ]]; then
    log "        Processing contexts from $protection_source protection..."
    pr_statuses=""
    checkmarx_statuses=""
    checkmarx_details=""
    
    IFS='|' read -ra pipelines <<< "$contexts"
    for pipeline in "${pipelines[@]}"; do
      [[ -z "$pipeline" ]] && continue
      
      log "          Processing pipeline: $pipeline"
      
      if [[ "$pipeline" =~ ^pull-request-validation-.*\/ADO$ ]]; then
        log "            → Standalone repo pattern detected"
        local pr_status=$(process_standalone_validation "$org" "$repo" "$pipeline")
        local checkmarx_status="enabled"
        local checkmarx_detail="standalone_repo"
      else
        local pipeline_cleaned=$(clean_pipeline_name "$pipeline")
        
        local lookup_result=$(lookup_pipeline_info "$org" "$pipeline_cleaned" "$branch")
        local found_entry=$(echo "$lookup_result" | cut -d'|' -f1-3)
        local lookup_source=$(echo "$lookup_result" | cut -d'|' -f4)
        
        if [[ -n "$found_entry" && "$lookup_source" != "not_found" ]]; then
          log "            → Found in $lookup_source lookup"
          IFS='|' read org_ado project pipeline_id <<< "$found_entry"
          local token=$( [[ "$org_ado" == "TDL-TCP-DEV" ]] && echo "$AZDO_PAT_DEV" || echo "$AZDO_PAT_HE" )
          local pr_status=$(is_pr_validation_enabled "$org_ado" "$project" "$pipeline_id" "$token")
          
          local checkmarx_result=$(check_checkmarx_in_pipeline "$org_ado" "$project" "$pipeline_id" "$token")
          local checkmarx_status=$(echo "$checkmarx_result" | cut -d'|' -f1)
          local checkmarx_detail=$(echo "$checkmarx_result" | cut -d'|' -f2)
          
          log "            → PR validation: $pr_status, Checkmarx: $checkmarx_status"
        else
          log "            → Pipeline not found in lookup tables"
          local pr_status="disabled"
          local checkmarx_status="enabled"
          local checkmarx_detail="pipeline_not_found"
        fi
      fi
      
      pr_statuses+="$pr_status|"
      checkmarx_statuses+="$checkmarx_status|"
      checkmarx_details+="$checkmarx_detail|"
    done
    
    pr_statuses="${pr_statuses%|}"
    pr_statuses="${pr_statuses//|/;}"
    checkmarx_statuses="${checkmarx_statuses%|}"  
    checkmarx_statuses="${checkmarx_statuses//|/;}"
    checkmarx_details="${checkmarx_details%|}"
    checkmarx_details="${checkmarx_details//|/;}"
    
    log "        Final result: Protection=$protection_source"
  else
    log "        No status checks configured for branch: $branch"
  fi
  
  # Step 4: Determine final status
  local required_status="no"
  if [[ "$status_enabled" == "true" ]]; then
    required_status="yes"
  fi
  
  # If no contexts, set everything to "no"
  if [[ -z "$contexts" || "$contexts" == "" ]]; then
    contexts="no"
    pr_statuses="no"
    checkmarx_statuses="no"
    checkmarx_details="no_contexts"
  else
    contexts="${contexts//|/;}"
  fi
  
  # Return format: required_status|contexts|pr_statuses|checkmarx_statuses|checkmarx_details|protection_source
  echo "$required_status|$contexts|$pr_statuses|$checkmarx_statuses|$checkmarx_details|$protection_source"
}

# ============================================================================
# ORGANIZATION PROCESSING
# ============================================================================

# Process organization
process_organization() {
  local org="$1"
  local output_file="output_${org}.csv"
  
  log "Processing GitHub Org: $org"
  
  [[ "$org" == "$STRATEGIC_INITIATIVE_GITHUB_ORG" ]] && log "🎯 Strategic Initiative organization detected"
  
  echo "GitHub_Org,Repository,Branch,Status_Checks_Required,Contexts,PR_Validation_Status,Checkmarx_Status,Checkmarx_Details,Protection_Source" > "$output_file"
  
  local page=1
  while :; do
    local repos=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/orgs/$org/repos?per_page=100&page=$page")
    local repo_names=$(echo "$repos" | jq -r '.[].name' 2>/dev/null)
    [[ -z "$repo_names" ]] && break
 
    for repo in $repo_names; do
      log "  Repo: $repo"
      
      local target_branches=("main" "staging" "release")
      
      for target_branch in "${target_branches[@]}"; do
        log "    Processing target branch: $target_branch"
        
        local protection_details=$(get_branch_protection_details "$org" "$repo" "$target_branch")
        local status_required=$(echo "$protection_details" | cut -d'|' -f1)
        local contexts=$(echo "$protection_details" | cut -d'|' -f2)
        local pr_statuses=$(echo "$protection_details" | cut -d'|' -f3)
        local checkmarx_statuses=$(echo "$protection_details" | cut -d'|' -f4)
        local checkmarx_details=$(echo "$protection_details" | cut -d'|' -f5)
        local protection_source=$(echo "$protection_details" | cut -d'|' -f6)
        
        # Write clean CSV line
        echo "$org,$repo,$target_branch,$status_required,$contexts,$pr_statuses,$checkmarx_statuses,$checkmarx_details,$protection_source" >> "$output_file"
        
        # Check compliance with checkmarx_status included
        check_compliance "$org" "$repo" "$target_branch" "$status_required" "$contexts" "$pr_statuses" "$checkmarx_statuses"
      done
    done
    ((page++))
  done
  
  log "✓ Completed processing: $org"
}

# Select organizations function with robust error handling
select_organizations() {
  log "Fetching available GitHub organizations..."
  
  local test_response=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/user" -o /dev/null)
  if [[ "$test_response" != "200" ]]; then
    log "Error: GitHub API connection failed (HTTP $test_response)"
    log "Please check your GitHub token permissions"
    exit 1
  fi
  
  local orgs_response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/user/orgs")
  
  if [[ -z "$orgs_response" ]]; then
    log "Error: Empty response from GitHub API"
    exit 1
  fi
  
  if echo "$orgs_response" | jq -e '.message' >/dev/null 2>&1; then
    local error_msg=$(echo "$orgs_response" | jq -r '.message')
    log "Error from GitHub API: $error_msg"
    exit 1
  fi
  
  if ! echo "$orgs_response" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log "Error: Invalid response format"
    exit 1
  fi
  
  local orgs=$(echo "$orgs_response" | jq -r '.[].login')
  
  if [[ -z "$orgs" ]]; then
    log "No organizations found"
    exit 1
  fi
  
  local org_array=()
  while IFS= read -r org; do
    org_array+=("$org")
  done <<< "$orgs"
  
  echo "" >&2
  echo "Available GitHub Organizations:" >&2
  echo "===============================" >&2
  for i in "${!org_array[@]}"; do
    printf "%2d. %s" $((i+1)) "${org_array[$i]}" >&2
    [[ "${org_array[$i]}" == "$STRATEGIC_INITIATIVE_GITHUB_ORG" ]] && printf " 🎯" >&2
    printf "\n" >&2
  done
  echo "" >&2
  printf "%2s. %s\n" "A" "All organizations" >&2
  echo "" >&2
  
  local selected_orgs=()
  while true; do
    echo "Select organization(s) to process:" >&2
    echo "• Number (1-${#org_array[@]}) for specific org" >&2
    echo "• 'A' for all organizations" >&2
    echo "• Multiple numbers separated by spaces" >&2
    echo "• 'q' to quit" >&2
    echo "" >&2
    read -p "Selection: " selection
    
    [[ "$selection" == "q" ]] && { log "Exiting..."; exit 0; }
    
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
        echo "Invalid selection: $num" >&2
        valid_selection=false
        break
      fi
    done
    
    if [[ "$valid_selection" == true ]] && [[ ${#selected_orgs[@]} -gt 0 ]]; then
      log "Selected organizations:"
      for org in "${selected_orgs[@]}"; do
        log "  $org"
      done
      break
    fi
    echo "" >&2
  done
  
  SELECTED_ORGS=("${selected_orgs[@]}")
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

log "======================================"
log "GitHub Azure DevOps Pipeline Validation Report Generator"
log "Enhanced with Dual Branch Protection Detection & Checkmarx Status"
log "Using Azure VM Managed Identity for authentication"
log "======================================"

# Check required tools
if ! command -v jq &> /dev/null; then
  log "Error: jq is required. Install with: sudo apt-get install jq"
  exit 1
fi

if ! command -v curl &> /dev/null; then
  log "Error: curl is required. Install with: sudo apt-get install curl"
  exit 1
fi

# Load tokens from Azure Key Vault using Managed Identity
load_tokens_from_akv_managed_identity

# Load ignore list
log "Loading ignore list..."
load_ignore_to_lookup

# Select organizations
select_organizations

# Load pipeline data
log "Loading pipeline data..."
load_csv_to_lookup "$CSV_DEV" PIPELINE_LOOKUP_DEV
load_csv_to_lookup "$CSV_HE" PIPELINE_LOOKUP_HE

log "Pipeline lookup summary:"
log "  DEV pipelines: ${#PIPELINE_LOOKUP_DEV[@]}"
log "  HE pipelines: ${#PIPELINE_LOOKUP_HE[@]}"
log "  Ignored repositories: ${#IGNORE_LOOKUP[@]}"

# Process selected organizations
log "Starting processing for ${#SELECTED_ORGS[@]} organization(s)..."
for org in "${SELECTED_ORGS[@]}"; do
  log "======================================"
  log "Processing Organization: $org"
  log "======================================"
  
  load_owners_to_lookup "$org"
  process_organization "$org"
done

# Generate non-compliant CSV files
generate_non_compliant_csv

log "======================================"
log "PROCESSING COMPLETE"
log "======================================"
log "Output files generated:"
for org in "${SELECTED_ORGS[@]}"; do
  log "  Main report: output_${org}.csv"
done
log "  Non-compliant reports: non-compliant_{org_name}.csv (if any)"
log ""
log "CSV OUTPUT FORMAT:"
log "✓ Status_Checks_Required: yes/no (branch protection with status checks)"
log "✓ Contexts: pipeline names or 'no'"  
log "✓ PR_Validation_Status: enabled/disabled/no"
log "✓ Checkmarx_Status: enabled/disabled/no (any disabled task = disabled)"
log "✓ Checkmarx_Details: disabled task names or status info"
log "✓ Protection_Source: classic/ruleset/none"
log ""
log "COMPLIANCE RULES:"
log "✓ Compliant: yes + pipelines + enabled + enabled"
log "✗ Non-compliant: no status checks"
log "✗ Non-compliant: status checks but no contexts"
log "✗ Non-compliant: contexts but PR validation disabled"
log "✗ Non-compliant: PR enabled but Checkmarx disabled/missing"
log ""
log "Summary: Processed ${#SELECTED_ORGS[@]} organization(s) successfully using Azure VM Managed Identity"
