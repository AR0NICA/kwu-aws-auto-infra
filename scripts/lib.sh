#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_NAME="aws-auto-infra"
readonly AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
readonly DEV_REGION="${AUTO_INFRA_DEV_REGION:-us-east-1}"
readonly TF_DIR="$ROOT_DIR/terraform"
readonly RUNTIME_DIR="$ROOT_DIR/.auto-infra"
readonly OUTPUT_DIR="$ROOT_DIR/outputs"
readonly TERRAFORM_VERSION="1.15.6"
TERRAFORM_BIN="${TERRAFORM_BIN:-$HOME/bin/terraform}"
readonly VPC_NAME="KWU-PRD-VPC"
readonly VPC_CIDR="10.250.0.0/16"
readonly DEV_VPC_NAME="KWU-DEV-VPC"
readonly DEV_VPC_CIDR="10.230.0.0/16"

LOG_FILE=""
ACCOUNT_ID=""
BACKEND_BUCKET=""
DOMAIN_NAME=""
KEY_NAME=""
ADMIN_CIDR=""

init_log() {
  mkdir -p "$OUTPUT_DIR" "$RUNTIME_DIR"
  LOG_FILE="$OUTPUT_DIR/auto_infra_$(date '+%Y%m%d_%H%M%S').log"
  : > "$LOG_FILE"
}

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}

say() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*"
  log "$level" "$*"
}

fail() {
  say ERROR "$*" >&2
  return 1
}

banner() {
  printf '\n============================================================\n'
  printf '                 AWS AUTO INFRA - TERRAFORM\n'
  printf '============================================================\n'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

normalize_domain() {
  local domain="${1,,}"
  domain="${domain//[[:space:]]/}"
  printf '%s\n' "${domain%.}"
}

validate_key_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,255}$ ]]
}

prompt_domain() {
  local input requested_domain
  while true; do
    read -r -p 'Enter the Route 53 domain name: ' input || return 1
    input="${input%$'\r'}"
    DOMAIN_NAME="$(normalize_domain "$input")"
    requested_domain="$DOMAIN_NAME"
    if [[ "$DOMAIN_NAME" == www.* ]]; then
      DOMAIN_NAME="${DOMAIN_NAME#www.}"
      say INFO "Using apex domain $DOMAIN_NAME instead of $requested_domain."
    fi
    if validate_domain "$DOMAIN_NAME"; then
      return 0
    fi
    say ERROR 'Enter a valid apex domain, for example: example.com'
  done
}

prompt_key_name() {
  local input
  while true; do
    read -r -p 'Enter the existing EC2 key pair name: ' input || return 1
    input="${input%$'\r'}"
    KEY_NAME="$input"
    if validate_key_name "$KEY_NAME"; then
      return 0
    fi
    say ERROR 'The key pair name may contain only letters, numbers, dots, underscores, and hyphens.'
  done
}

state_key() {
  printf 'deployments/%s/terraform.tfstate\n' "$DOMAIN_NAME"
}

ensure_terraform() {
  if command -v terraform >/dev/null 2>&1; then
    TERRAFORM_BIN="$(command -v terraform)"
    return 0
  fi
  if [[ -x "$TERRAFORM_BIN" ]]; then
    return 0
  fi

  say INFO "Terraform was not found. Installing Terraform $TERRAFORM_VERSION..."
  require_command curl || return 1
  require_command unzip || return 1
  require_command sha256sum || return 1
  local temp_dir archive checksums expected actual
  temp_dir="$(mktemp -d)" || return 1
  archive="$temp_dir/terraform.zip"
  checksums="$temp_dir/SHA256SUMS"
  curl --fail --silent --show-error --location \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    --output "$archive" || { rm -rf "$temp_dir"; return 1; }
  curl --fail --silent --show-error --location \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
    --output "$checksums" || { rm -rf "$temp_dir"; return 1; }
  expected="$(awk '/terraform_'"$TERRAFORM_VERSION"'_linux_amd64.zip$/ {print $1}' "$checksums")"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || { rm -rf "$temp_dir"; fail 'Terraform archive checksum verification failed.'; return 1; }
  mkdir -p "$(dirname "$TERRAFORM_BIN")" || { rm -rf "$temp_dir"; return 1; }
  unzip -q "$archive" -d "$(dirname "$TERRAFORM_BIN")" || { rm -rf "$temp_dir"; return 1; }
  chmod 0755 "$TERRAFORM_BIN" || { rm -rf "$temp_dir"; return 1; }
  rm -rf "$temp_dir"
  say OK "Installed Terraform: $TERRAFORM_BIN"
}

configure_aws() {
  require_command aws || return 1
  require_command jq || return 1
  export AWS_PAGER=""
  export AWS_DEFAULT_REGION="$AWS_REGION"
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || { fail 'AWS credentials are not valid.'; return 1; }
  BACKEND_BUCKET="aws-auto-infra-tfstate-${ACCOUNT_ID}-${AWS_REGION}"
  say OK "AWS credentials validated for account $ACCOUNT_ID in $AWS_REGION."
}

ensure_backend_bucket() {
  if ! aws s3api head-bucket --bucket "$BACKEND_BUCKET" 2>/dev/null; then
    say INFO "Creating Terraform state bucket: $BACKEND_BUCKET"
    aws s3api create-bucket --bucket "$BACKEND_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null || return 1
  fi
  aws s3api put-bucket-versioning --bucket "$BACKEND_BUCKET" --versioning-configuration Status=Enabled || return 1
  aws s3api put-bucket-encryption --bucket "$BACKEND_BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' || return 1
  aws s3api put-public-access-block --bucket "$BACKEND_BUCKET" \
    --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' || return 1
  aws s3api put-bucket-ownership-controls --bucket "$BACKEND_BUCKET" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' || return 1
  aws s3api put-bucket-tagging --bucket "$BACKEND_BUCKET" \
    --tagging "TagSet=[{Key=Project,Value=$PROJECT_NAME},{Key=ManagedBy,Value=auto_infra.sh}]" || return 1
  say OK "Terraform backend is ready: s3://$BACKEND_BUCKET/$(state_key)"
}

initialize_terraform() {
  ensure_terraform || return 1
  configure_aws || return 1
  ensure_backend_bucket || return 1
  "$TERRAFORM_BIN" -chdir="$TF_DIR" init -input=false -reconfigure \
    -backend-config="bucket=$BACKEND_BUCKET" \
    -backend-config="key=$(state_key)" \
    -backend-config="region=$AWS_REGION" \
    -backend-config='encrypt=true' \
    -backend-config='use_lockfile=true' | tee -a "$LOG_FILE" || return 1
}

detect_admin_cidr() {
  if [[ -n "${AUTO_INFRA_ADMIN_CIDR:-}" ]]; then
    ADMIN_CIDR="$AUTO_INFRA_ADMIN_CIDR"
  else
    local address
    address="$(curl --fail --silent --show-error https://checkip.amazonaws.com | tr -d '[:space:]')" || { fail 'Unable to determine the CloudShell public IP. Set AUTO_INFRA_ADMIN_CIDR and retry.'; return 1; }
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { fail 'The public IP service returned an invalid IPv4 address.'; return 1; }
    ADMIN_CIDR="$address/32"
  fi
}

route53_zone_id() {
  aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN_NAME." \
    --query "HostedZones[?Name=='$DOMAIN_NAME.' && Config.PrivateZone==\`false\`].Id | [0]" --output text | sed 's#^/hostedzone/##'
}

verify_prerequisites() {
  local found_key dev_found_key zone_id
  found_key="$(aws ec2 describe-key-pairs --key-names "$KEY_NAME" --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)"
  [[ "$found_key" == "$KEY_NAME" ]] || { fail "EC2 key pair was not found in $AWS_REGION: $KEY_NAME"; return 1; }
  dev_found_key="$(aws ec2 describe-key-pairs --region "$DEV_REGION" --key-names "$KEY_NAME" --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)"
  [[ "$dev_found_key" == "$KEY_NAME" ]] || { fail "EC2 key pair was not found in $DEV_REGION: $KEY_NAME. EC2 key pairs are regional, so create or import the same key name there before running."; return 1; }
  zone_id="$(route53_zone_id)" || return 1
  [[ -n "$zone_id" && "$zone_id" != 'None' ]] || { fail "No exact public Route 53 hosted zone exists for $DOMAIN_NAME."; return 1; }
}

assert_records_unused() {
  local zone_id record records
  zone_id="$(route53_zone_id)" || return 1
  [[ -n "$zone_id" && "$zone_id" != 'None' ]] || { fail "No exact public Route 53 hosted zone exists for $DOMAIN_NAME."; return 1; }
  for record in "$DOMAIN_NAME" "www.$DOMAIN_NAME"; do
    records="$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
      --query "ResourceRecordSets[?Name=='$record.' && (Type=='A' || Type=='AAAA' || Type=='CNAME')]" --output json)" || return 1
    [[ "$(jq 'length' <<<"$records")" == '0' ]] || { fail "Existing DNS record blocks automation: $record. Remove or import it before creation."; return 1; }
  done
}

assert_no_legacy_stack() {
  local existing dev_existing
  existing="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" "Name=cidr-block,Values=$VPC_CIDR" --query 'Vpcs[].VpcId' --output text)"
  [[ -z "$existing" || "$existing" == 'None' ]] || { fail "An unmanaged legacy VPC already uses $VPC_CIDR: $existing. Delete or import it before creation."; return 1; }
  dev_existing="$(aws ec2 describe-vpcs --region "$DEV_REGION" --filters "Name=tag:Name,Values=$DEV_VPC_NAME" "Name=cidr-block,Values=$DEV_VPC_CIDR" --query 'Vpcs[].VpcId' --output text)"
  [[ -z "$dev_existing" || "$dev_existing" == 'None' ]] || { fail "An unmanaged legacy DEV VPC already uses $DEV_VPC_CIDR in $DEV_REGION: $dev_existing. Delete or import it before creation."; return 1; }
}

write_variables() {
  detect_admin_cidr || return 1
  cat > "$RUNTIME_DIR/terraform.tfvars.json" <<EOF
{
  "aws_region": "$AWS_REGION",
  "dev_region": "$DEV_REGION",
  "domain_name": "$DOMAIN_NAME",
  "key_name": "$KEY_NAME",
  "admin_cidr": "$ADMIN_CIDR"
}
EOF
}

terraform_state_exists() {
  aws s3api head-object \
    --bucket "$BACKEND_BUCKET" \
    --key "$(state_key)" >/dev/null 2>&1
}

create_infrastructure() {
  banner
  prompt_domain || return 0
  prompt_key_name || return 0
  initialize_terraform || return 1
  verify_prerequisites || return 1
  local state_entries
  if terraform_state_exists; then
    state_entries="$("$TERRAFORM_BIN" -chdir="$TF_DIR" state list)" || return 1
  else
    state_entries=""
  fi
  if [[ -z "$state_entries" ]]; then
    assert_records_unused || return 1
    assert_no_legacy_stack || return 1
  else
    say INFO 'Existing Terraform state found. Applying the managed deployment update.'
  fi
  write_variables || return 1
  say INFO 'Creating infrastructure. RDS and ACM validation can take several minutes.'
  "$TERRAFORM_BIN" -chdir="$TF_DIR" apply -auto-approve -input=false -var-file="$RUNTIME_DIR/terraform.tfvars.json" | tee -a "$LOG_FILE" || return 1
  say OK 'Deployment completed. Run menu option 3 in a new session to verify ALB and database connectivity.'
}

delete_state_versions() {
  local key objects
  key="$(state_key)"
  objects="$(aws s3api list-object-versions --bucket "$BACKEND_BUCKET" --prefix "$key" --output json | jq -c --arg key "$key" '[.Versions[]?, .DeleteMarkers[]? | select(.Key == $key) | {Key: .Key, VersionId: .VersionId}]')"
  [[ "$objects" == '[]' ]] || aws s3api delete-objects --bucket "$BACKEND_BUCKET" --delete "{\"Objects\":$objects,\"Quiet\":true}" >/dev/null
}

delete_empty_backend_bucket() {
  local tagged remaining
  tagged="$(aws s3api get-bucket-tagging --bucket "$BACKEND_BUCKET" --output json 2>/dev/null | jq -r '.TagSet[]? | select(.Key == "Project") | .Value' || true)"
  remaining="$(aws s3api list-object-versions --bucket "$BACKEND_BUCKET" --max-items 1 --output json | jq '[.Versions[]?, .DeleteMarkers[]?] | length')"
  if [[ "$tagged" == "$PROJECT_NAME" && "$remaining" == '0' ]]; then
    aws s3api delete-bucket --bucket "$BACKEND_BUCKET" --region "$AWS_REGION"
    say OK "Deleted empty Terraform backend bucket: $BACKEND_BUCKET"
  fi
}

delete_infrastructure() {
  banner
  prompt_domain || return 0
  prompt_key_name || return 0
  read -r -p "Destroy all Terraform-managed infrastructure for $DOMAIN_NAME? [y/N]: " answer
  answer="${answer%$'\r'}"
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { say INFO 'Deletion cancelled.'; return 0; }
  initialize_terraform || return 1
  write_variables || return 1
  say INFO 'Destroying Terraform-managed infrastructure. RDS data will be permanently deleted.'
  "$TERRAFORM_BIN" -chdir="$TF_DIR" destroy -auto-approve -input=false -var-file="$RUNTIME_DIR/terraform.tfvars.json" | tee -a "$LOG_FILE" || return 1
  delete_state_versions || return 1
  delete_empty_backend_bucket || return 1
  say OK 'Infrastructure deletion completed.'
}

test_application() {
  local prompt="${1:-true}" domain_url target_group_arn states response attempt board_status board_headers
  if [[ "$prompt" == true ]]; then
    banner
    prompt_domain || return 0
    initialize_terraform || return 1
  fi
  domain_url="https://$DOMAIN_NAME"
  target_group_arn="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw alb_target_group_arn 2>/dev/null)" || { fail 'No Terraform-managed ALB target group exists for this domain.'; return 1; }
  [[ -n "$target_group_arn" ]] || { fail 'No Terraform-managed ALB target group exists for this domain.'; return 1; }
  states=""
  for attempt in {1..30}; do
    states="$(aws elbv2 describe-target-health --target-group-arn "$target_group_arn" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)" || return 1
    [[ "$states" == *healthy* && "$(wc -w <<<"$states")" -eq 2 ]] && break
    sleep 10
  done
  [[ "$states" == *healthy* && "$(wc -w <<<"$states")" -eq 2 ]] || { fail "ALB targets are not both healthy: ${states:-none}"; return 1; }
  board_headers="$(mktemp)"
  board_status="$(curl --silent --output /dev/null --dump-header "$board_headers" --write-out '%{http_code}' --location --max-time 10 "$domain_url/app/" 2>/dev/null || true)"
  if [[ "$board_status" != '200' ]]; then
    fail "The board page did not return HTTP 200. Current status: ${board_status:-request_failed}"
    say INFO 'Response headers from /app/:'
    sed 's/\r$//' "$board_headers" | awk 'NF {print "  " $0}'
    rm -f "$board_headers"
    return 1
  fi
  rm -f "$board_headers"
  say OK 'Board page returned HTTP 200.'
  for attempt in {1..30}; do
    response="$(curl --fail --silent --show-error --location --max-time 10 "$domain_url/app/health.jsp" 2>/dev/null || true)"
    [[ "$response" == *'database=connected'* ]] && break
    sleep 10
  done
  [[ "$response" == *'database=connected'* ]] || { fail 'The HTTPS application health check did not confirm database connectivity.'; return 1; }
  say OK 'ALB targets are healthy and the Tomcat board is connected to RDS.'
}

draw_menu() {
  banner
  printf '1) Create infrastructure\n'
  printf '2) Delete all infrastructure\n'
  printf '3) Test ALB and application connectivity\n'
  printf '4) Exit\n\n'
}

main() {
  init_log
  while true; do
    draw_menu
    read -r -p 'Select an option [1-4]: ' choice || choice=4
    choice="${choice%$'\r'}"
    case "$choice" in
      1) if create_infrastructure; then say INFO 'Creation completed. Exiting.'; return 0; else say ERROR 'Creation failed. No further deployment steps were run.'; fi ;;
      2) if ! delete_infrastructure; then say ERROR 'Deletion failed. Check the log before retrying.'; fi ;;
      3) if ! test_application true; then say ERROR 'Connectivity test failed.'; fi ;;
      4) say INFO 'Exiting.'; return 0 ;;
      *) say ERROR 'Invalid selection. Enter a number from 1 to 4.' ;;
    esac
    printf '\nPress Enter to continue...'
    read -r _ || true
  done
}
