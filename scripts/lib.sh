#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_NAME="aws-auto-infra"
readonly AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
readonly TF_DIR="$ROOT_DIR/terraform"
readonly RUNTIME_DIR="$ROOT_DIR/.auto-infra"
readonly OUTPUT_DIR="$ROOT_DIR/outputs"
readonly TERRAFORM_VERSION="1.15.6"
TERRAFORM_BIN="${TERRAFORM_BIN:-$HOME/bin/terraform}"
readonly VPC_NAME="KWU-PRD-VPC"
readonly VPC_CIDR="10.250.0.0/16"

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
  local input
  while true; do
    read -r -p 'Enter the Route 53 domain name: ' input || return 1
    input="${input%$'\r'}"
    DOMAIN_NAME="$(normalize_domain "$input")"
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
  require_command curl
  require_command unzip
  require_command sha256sum
  local temp_dir archive checksums expected actual
  temp_dir="$(mktemp -d)"
  archive="$temp_dir/terraform.zip"
  checksums="$temp_dir/SHA256SUMS"
  curl --fail --silent --show-error --location \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    --output "$archive"
  curl --fail --silent --show-error --location \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
    --output "$checksums"
  expected="$(awk '/terraform_'"$TERRAFORM_VERSION"'_linux_amd64.zip$/ {print $1}' "$checksums")"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || { rm -rf "$temp_dir"; fail 'Terraform archive checksum verification failed.'; }
  mkdir -p "$(dirname "$TERRAFORM_BIN")"
  unzip -q "$archive" -d "$(dirname "$TERRAFORM_BIN")"
  chmod 0755 "$TERRAFORM_BIN"
  rm -rf "$temp_dir"
  say OK "Installed Terraform: $TERRAFORM_BIN"
}

configure_aws() {
  require_command aws
  require_command jq
  export AWS_PAGER=""
  export AWS_DEFAULT_REGION="$AWS_REGION"
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || fail 'AWS credentials are not valid.'
  BACKEND_BUCKET="aws-auto-infra-tfstate-${ACCOUNT_ID}-${AWS_REGION}"
  say OK "AWS credentials validated for account $ACCOUNT_ID in $AWS_REGION."
}

ensure_backend_bucket() {
  if ! aws s3api head-bucket --bucket "$BACKEND_BUCKET" 2>/dev/null; then
    say INFO "Creating Terraform state bucket: $BACKEND_BUCKET"
    aws s3api create-bucket --bucket "$BACKEND_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
  aws s3api put-bucket-versioning --bucket "$BACKEND_BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BACKEND_BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$BACKEND_BUCKET" \
    --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
  aws s3api put-bucket-ownership-controls --bucket "$BACKEND_BUCKET" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  aws s3api put-bucket-tagging --bucket "$BACKEND_BUCKET" \
    --tagging "TagSet=[{Key=Project,Value=$PROJECT_NAME},{Key=ManagedBy,Value=auto_infra.sh}]"
  say OK "Terraform backend is ready: s3://$BACKEND_BUCKET/$(state_key)"
}

initialize_terraform() {
  ensure_terraform
  configure_aws
  ensure_backend_bucket
  "$TERRAFORM_BIN" -chdir="$TF_DIR" init -input=false -reconfigure \
    -backend-config="bucket=$BACKEND_BUCKET" \
    -backend-config="key=$(state_key)" \
    -backend-config="region=$AWS_REGION" \
    -backend-config='encrypt=true' \
    -backend-config='use_lockfile=true' | tee -a "$LOG_FILE"
}

detect_admin_cidr() {
  if [[ -n "${AUTO_INFRA_ADMIN_CIDR:-}" ]]; then
    ADMIN_CIDR="$AUTO_INFRA_ADMIN_CIDR"
  else
    local address
    address="$(curl --fail --silent --show-error https://checkip.amazonaws.com | tr -d '[:space:]')" || fail 'Unable to determine the CloudShell public IP. Set AUTO_INFRA_ADMIN_CIDR and retry.'
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail 'The public IP service returned an invalid IPv4 address.'
    ADMIN_CIDR="$address/32"
  fi
}

route53_zone_id() {
  aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN_NAME." \
    --query "HostedZones[?Name=='$DOMAIN_NAME.' && Config.PrivateZone==\`false\`].Id | [0]" --output text | sed 's#^/hostedzone/##'
}

verify_prerequisites() {
  local found_key zone_id
  found_key="$(aws ec2 describe-key-pairs --key-names "$KEY_NAME" --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)"
  [[ "$found_key" == "$KEY_NAME" ]] || fail "EC2 key pair was not found in $AWS_REGION: $KEY_NAME"
  zone_id="$(route53_zone_id)"
  [[ -n "$zone_id" && "$zone_id" != 'None' ]] || fail "No exact public Route 53 hosted zone exists for $DOMAIN_NAME."
}

assert_records_unused() {
  local zone_id record records
  zone_id="$(route53_zone_id)"
  for record in "$DOMAIN_NAME" "www.$DOMAIN_NAME"; do
    records="$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
      --query "ResourceRecordSets[?Name=='$record.' && (Type=='A' || Type=='AAAA' || Type=='CNAME')]" --output json)"
    [[ "$(jq 'length' <<<"$records")" == '0' ]] || fail "Existing DNS record blocks automation: $record. Remove or import it before creation."
  done
}

assert_no_legacy_stack() {
  local existing
  existing="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" "Name=cidr-block,Values=$VPC_CIDR" --query 'Vpcs[].VpcId' --output text)"
  [[ -z "$existing" || "$existing" == 'None' ]] || fail "An unmanaged legacy VPC already uses $VPC_CIDR: $existing. Delete or import it before creation."
}

write_variables() {
  detect_admin_cidr
  cat > "$RUNTIME_DIR/terraform.tfvars.json" <<EOF
{
  "aws_region": "$AWS_REGION",
  "domain_name": "$DOMAIN_NAME",
  "key_name": "$KEY_NAME",
  "admin_cidr": "$ADMIN_CIDR"
}
EOF
}

show_outputs() {
  say OK 'Deployment completed.'
  "$TERRAFORM_BIN" -chdir="$TF_DIR" output
}

create_infrastructure() {
  banner
  prompt_domain || return 0
  prompt_key_name || return 0
  initialize_terraform
  verify_prerequisites
  if [[ -z "$("$TERRAFORM_BIN" -chdir="$TF_DIR" state list 2>/dev/null || true)" ]]; then
    assert_records_unused
    assert_no_legacy_stack
  else
    say INFO 'Existing Terraform state found. Applying the managed deployment update.'
  fi
  write_variables
  say INFO 'Creating infrastructure. RDS and ACM validation can take several minutes.'
  "$TERRAFORM_BIN" -chdir="$TF_DIR" apply -auto-approve -input=false -var-file="$RUNTIME_DIR/terraform.tfvars.json" | tee -a "$LOG_FILE"
  show_outputs
  test_application false
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
  initialize_terraform
  write_variables
  say INFO 'Destroying Terraform-managed infrastructure. RDS data will be permanently deleted.'
  "$TERRAFORM_BIN" -chdir="$TF_DIR" destroy -auto-approve -input=false | tee -a "$LOG_FILE"
  delete_state_versions
  delete_empty_backend_bucket
  say OK 'Infrastructure deletion completed.'
}

test_application() {
  local prompt="${1:-true}" domain_url target_group_arn states response attempt
  if [[ "$prompt" == true ]]; then
    banner
    prompt_domain || return 0
    initialize_terraform
  fi
  domain_url="https://$DOMAIN_NAME"
  target_group_arn="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw alb_target_group_arn 2>/dev/null || true)"
  [[ -n "$target_group_arn" ]] || fail 'No Terraform-managed ALB target group exists for this domain.'
  states=""
  for attempt in {1..30}; do
    states="$(aws elbv2 describe-target-health --target-group-arn "$target_group_arn" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
    [[ "$states" == *healthy* && "$(wc -w <<<"$states")" -eq 2 ]] && break
    sleep 10
  done
  [[ "$states" == *healthy* && "$(wc -w <<<"$states")" -eq 2 ]] || fail "ALB targets are not both healthy: ${states:-none}"
  for attempt in {1..30}; do
    response="$(curl --fail --silent --show-error --location --max-time 10 "$domain_url/app/health.jsp" 2>/dev/null || true)"
    [[ "$response" == *'database=connected'* ]] && break
    sleep 10
  done
  [[ "$response" == *'database=connected'* ]] || fail 'The HTTPS application health check did not confirm database connectivity.'
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
      1) create_infrastructure || true ;;
      2) delete_infrastructure || true ;;
      3) test_application true || true ;;
      4) say INFO 'Exiting.'; return 0 ;;
      *) say ERROR 'Invalid selection. Enter a number from 1 to 4.' ;;
    esac
    printf '\nPress Enter to continue...'
    read -r _ || true
  done
}
