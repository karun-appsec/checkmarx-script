#!/usr/bin/env bash

# --- CONFIGURATION ---
GITHUB_API="https://api.github.com"

# Azure Key Vault Configuration - UPDATED WITH YOUR VALUES
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

# Logging function with IST time
log() {
  local ist_time=$(TZ='Asia/Kolkata' date +"%Y-%m-%d %H:%M:%S IST")
  # --- FIX: Redirect echo to standard error (>&2) to prevent it from being captured by command substitution ---
  echo "[$ist_time] $*" >&2
}

# Function to check if Azure CLI is installed and authenticated
check_azure_cli() {
  log "Checking Azure CLI availability..."
  
  if ! command -v az &> /dev/null; then
    log "Error: Azure CLI is not installed"
    exit 1
  fi
  
  if ! az account show &> /dev/null; then
    log "Error: Not authenticated with Azure CLI"
    log "Run: az login"
    exit 1
  fi
  
  local subscription_name=$(az account show --query name -o tsv)
  log "✓ Azure CLI authenticated - Subscription: $subscription_name"
}

# Function to fetch secret from Azure Key Vault with error handling
get_secret_from_akv() {
  local secret_name="$1"
  local secret_value=""
  
  log "Fetching secret '$secret_name'..."
  
  secret_value=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$secret_name" --query value -o tsv 2>/dev/null)
  
  if [[ $? -ne 0 ]] || [[ -z "$secret_value" ]]; then
    log "Error: Failed to retrieve secret '$secret_name'"
    exit 1
  fi
  
  echo "$secret_value"
}

# Function to load all tokens from Azure Key Vault
load_tokens_from_akv() {
  log "Loading tokens from Azure Key Vault..."
  
  check_azure_cli
  
  # Fetch GitHub token (required)
  GITHUB_TOKEN=$(get_secret_from_akv "$GITHUB_TOKEN_SECRET_NAME")
  
  # Fetch Azure DevOps tokens (optional)
  if az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$AZDO_PAT_DEV_SECRET_NAME" >/dev/null 2>&1; then
    AZDO_PAT_DEV=$(get_secret_from_akv "$AZDO_PAT_DEV_SECRET_NAME")
  fi
  
  if az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$AZDO_PAT_HE_SECRET_NAME" >/dev/null 2>&1; then
    AZDO_PAT_HE=$(get_secret_from_akv "$AZDO_PAT_HE_SECRET_NAME")
  fi
  
  if [[ -z "$GITHUB_TOKEN" ]]; then
    log "Error: GitHub token is required but not available"
    exit 1
  fi
  
  log "✓ Tokens loaded successfully"
  log "  GitHub Token: ${GITHUB_TOKEN:0:7}... (${#GITHUB_TOKEN} chars)"
}

# Pipeline name cleaning
clean_pipeline_name() {
  local name="$1"
  echo "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//; s/"$//'
}

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
  
  # Clear existing entries for this org
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

# Enhanced pipeline lookup
lookup_pipeline_info() {
  local github_org="$1"
  local pipeline_name="$2"
  local branch="$3"
  
  local found_entry=""
  local lookup_source=""
  
  # Strategic initiative special handling
  if [[ "$github_org" == "$STRATEGIC_INITIATIVE_GITHUB_ORG" ]]; then
    local lookup_key="${STRATEGIC_INITIATIVE_ADO_PROJECT}|${pipeline_name}"
    
    found_entry="${PIPELINE_LOOKUP_DEV[$lookup_key]:-}"
    [[ -n "$found_entry" ]] && lookup_source="DEV-Strategic"
    
    if [[ -z "$found_entry" ]]; then
      found_entry="${PIPELINE_LOOKUP_HE[$lookup_key]:-}"
      [[ -n "$found_entry" ]] && lookup_source="HE-Strategic"
    fi
  fi
  
  # Standard lookup if strategic failed
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

# Compliance checking functions
normalize_value() {
    local value="$1"
    echo "$value" | sed 's/^"//;s/"$//' | xargs | tr '[:upper:]' '[:lower:]'
}

is_empty_or_na() {
    local value="$1"
    local normalized=$(normalize_value "$value")
    [[ "$normalized" == "" || "$normalized" == "na" || "$normalized" == "null" || "$normalized" == "none" || "$normalized" == "no" ]]
}

is_yes_or_enabled() {
    local value="$1"
    local normalized=$(normalize_value "$value")
    [[ "$normalized" == "yes" || "$normalized" == "enabled" || "$normalized" == "true" || "$normalized" == "required" ]]
}

has_disabled_pr_validation() {
    local pr_validation="$1"
    [[ "$pr_validation" =~ disabled ]]
}

# Check compliance and add to non-compliant list
check_compliance() {
    local org="$1" repo="$2" branch="$3" status_checks="$4" contexts="$5" pr_validation="$6"
    
    if should_ignore_repo "$org" "$repo"; then
        log "        ⚠️  Repository ignored"
        return 1
    fi
    
    local is_non_compliant=false
    local reason=""
    
    if is_empty_or_na "$status_checks"; then
        is_non_compliant=true
        reason="Status checks not required"
    elif is_yes_or_enabled "$status_checks"; then
        if is_empty_or_na "$contexts"; then
            is_non_compliant=true
            reason="Status checks required but no contexts configured"
        elif ! is_empty_or_na "$contexts" && has_disabled_pr_validation "$pr_validation"; then
            is_non_compliant=true
            reason="PR validation contains disabled status"
        fi
    fi
    
    if [ "$is_non_compliant" = true ]; then
        NON_COMPLIANT_REPOS["${org}|${repo}|${branch}"]="$org,$repo,$branch,$status_checks,$contexts,$pr_validation"
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
        
        echo "org,repo_name,branch,status_check,context,pr_validation,owner_email" > "$output_file"
        
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

# Azure DevOps pipeline validation
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

# Get branch protection details
get_branch_protection_details() {
  local org="$1" repo="$2" branch="$3"
  
  local protection=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/repos/$org/$repo/branches/$branch/protection" 2>/dev/null)
  
  if [[ $(echo "$protection" | jq -r '.message' 2>/dev/null) == "Branch not protected" ]]; then
    echo "NA|NA|NA"
    return
  fi
  
  local required=$(echo "$protection" | jq -r '.required_status_checks != null' 2>/dev/null)
  local required_status=$( [[ "$required" == "true" ]] && echo "YES" || echo "NO" )
  local contexts=$(echo "$protection" | jq -r '.required_status_checks.contexts // [] | join(";")' 2>/dev/null)
  
  [[ -z "$contexts" || "$contexts" == "[]" ]] && contexts="NA"
  
  local pr_statuses="NA"
  if [[ "$contexts" != "NA" && -n "$contexts" ]]; then
    pr_statuses=""
    IFS=';' read -ra pipelines <<< "$contexts"
    for pipeline in "${pipelines[@]}"; do
      [[ -z "$pipeline" ]] && continue
      
      if [[ "$pipeline" =~ ^pull-request-validation-.*\/ADO$ ]]; then
        pr_status=$(process_standalone_validation "$org" "$repo" "$pipeline")
      else
        local pipeline_cleaned=$(clean_pipeline_name "$pipeline")
        local lookup_result=$(lookup_pipeline_info "$org" "$pipeline_cleaned" "$branch")
        local found_entry=$(echo "$lookup_result" | cut -d'|' -f1-3)
        local lookup_source=$(echo "$lookup_result" | cut -d'|' -f4)
        
        if [[ -n "$found_entry" && "$lookup_source" != "not_found" ]]; then
          IFS='|' read org_ado project pipeline_id <<< "$found_entry"
          local token=$( [[ "$org_ado" == "TDL-TCP-DEV" ]] && echo "$AZDO_PAT_DEV" || echo "$AZDO_PAT_HE" )
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

# Process organization
process_organization() {
  local org="$1"
  local output_file="output_${org}.csv"
  
  log "Processing GitHub Org: $org"
  
  [[ "$org" == "$STRATEGIC_INITIATIVE_GITHUB_ORG" ]] && log "🎯 Strategic Initiative organization detected"
  
  echo "GitHub_Org,Repository,Branch,Status_Checks_Required,Contexts,PR_Validation_Status" > "$output_file"
  
  local page=1
  while :; do
    local repos=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/orgs/$org/repos?per_page=100&page=$page")
    local repo_names=$(echo "$repos" | jq -r '.[].name' 2>/dev/null)
    [[ -z "$repo_names" ]] && break

    for repo in $repo_names; do
      log "  Repo: $repo"
      
      local protected_branches=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API/repos/$org/$repo/branches?protected=true" 2>/dev/null)
      
      if [[ $(echo "$protected_branches" | jq -r 'type' 2>/dev/null) != "array" ]]; then
        for target_branch in "main" "staging" "release"; do
          echo "$org,$repo,$target_branch,NA,NA,NA" >> "$output_file"
          check_compliance "$org" "$repo" "$target_branch" "NA" "NA" "NA"
        done
        continue
      fi
      
      local protected_branch_names=$(echo "$protected_branches" | jq -r '.[].name' 2>/dev/null)
      
      if [[ -z "$protected_branch_names" ]]; then
        for target_branch in "main" "staging" "release"; do
          echo "$org,$repo,$target_branch,NA,NA,NA" >> "$output_file"
          check_compliance "$org" "$repo" "$target_branch" "NA" "NA" "NA"
        done
        continue
      fi
      
      local found_target_branches=()
      local target_branches=("main" "staging" "release")
      
      for branch in $protected_branch_names; do
        local branch_lower=$(echo "$branch" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$branch_lower" =~ $target_branches_regex ]]; then
          found_target_branches+=("$branch_lower")
          log "    Processing protected branch: $branch"
          
          local protection_details=$(get_branch_protection_details "$org" "$repo" "$branch")
          local status_required=$(echo "$protection_details" | cut -d'|' -f1)
          local contexts=$(echo "$protection_details" | cut -d'|' -f2)
          local pr_statuses=$(echo "$protection_details" | cut -d'|' -f3)
          
          if [[ "$status_required" == "NA" ]]; then
            echo "$org,$repo,$branch,NA,NA,NA" >> "$output_file"
            check_compliance "$org" "$repo" "$branch" "NA" "NA" "NA"
          else
            if [[ "$contexts" == "NA" ]]; then
              echo "$org,$repo,$branch,$status_required,NA,NA" >> "$output_file"
              check_compliance "$org" "$repo" "$branch" "$status_required" "NA" "NA"
            else
              echo "$org,$repo,$branch,$status_required,\"$contexts\",\"$pr_statuses\"" >> "$output_file"
              check_compliance "$org" "$repo" "$branch" "$status_required" "$contexts" "$pr_statuses"
            fi
          fi
        fi
      done
      
      for target_branch in "${target_branches[@]}"; do
        if [[ ! " ${found_target_branches[*]} " =~ " ${target_branch} " ]]; then
          echo "$org,$repo,$target_branch,NA,NA,NA" >> "$output_file"
          check_compliance "$org" "$repo" "$target_branch" "NA" "NA" "NA"
        fi
      done
    done
    ((page++))
  done
  
  log "✓ Completed processing: $org"
}

# Select organizations function with robust error handling
select_organizations() {
  log "Fetching available GitHub organizations..."
  
  # Test connection first
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

# --- MAIN EXECUTION ---
log "GitHub Azure DevOps Pipeline Validation Report Generator"

# Check required tools
if ! command -v jq &> /dev/null; then
  log "Error: jq is required. Install with: brew install jq"
  exit 1
fi

# Load tokens from Azure Key Vault
load_tokens_from_akv

# Load ignore list
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
log "  Non-compliant reports: non-compliant_{org_name}.csv"
log "Summary: Processed ${#SELECTED_ORGS[@]} organization(s) successfully"
