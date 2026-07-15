#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_NAME="aws-auto-infra"
readonly AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
readonly DEV_REGION="${AUTO_INFRA_DEV_REGION:-us-east-1}"
readonly TF_DIR="$ROOT_DIR/terraform"
readonly RUNTIME_DIR="$ROOT_DIR/.auto-infra"
readonly OUTPUT_DIR="$ROOT_DIR/outputs"
readonly LOGO_FILE="$ROOT_DIR/assets/auto-infra-logo.txt"
readonly TERRAFORM_VERSION="1.15.6"
TERRAFORM_BIN="${TERRAFORM_BIN:-$HOME/bin/terraform}"
readonly VPC_NAME="KWU-PRD-VPC"
readonly VPC_CIDR="10.250.0.0/16"
readonly DEV_VPC_NAME="KWU-DEV-VPC"
readonly DEV_VPC_CIDR="10.230.0.0/16"
readonly VPN_TEST_CIDR="172.31.240.0/24"

LOG_FILE=""
ACCOUNT_ID=""
BACKEND_BUCKET=""
DOMAIN_NAME=""

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
  if [[ -f "$LOGO_FILE" ]]; then
    cat "$LOGO_FILE"
    printf '\n'
  fi
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
  [[ "$AWS_REGION" == 'ap-northeast-2' ]] || { fail "This topology requires AWS_REGION=ap-northeast-2 because its PRD availability zones are fixed in Seoul. Current value: $AWS_REGION"; return 1; }
  [[ "$DEV_REGION" == 'us-east-1' ]] || { fail "This topology requires AUTO_INFRA_DEV_REGION=us-east-1 for the Virginia DEV/on-premises VPC. Current value: $DEV_REGION"; return 1; }
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

route53_zone_id() {
  aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN_NAME." \
    --query "HostedZones[?Name=='$DOMAIN_NAME.' && Config.PrivateZone==\`false\`].Id | [0]" --output text | sed 's#^/hostedzone/##'
}

verify_prerequisites() {
  local zone_id
  zone_id="$(route53_zone_id)" || return 1
  [[ -n "$zone_id" && "$zone_id" != 'None' ]] || { fail "No exact public Route 53 hosted zone exists for $DOMAIN_NAME."; return 1; }
}

assert_security_services_unused() {
  local state_entries="$1"
  local region prefix detector_address recorder_address channel_address hub_address session_document_address
  local detector_count recorder_count channel_count hub_arn hub_error_file document_count trail_count aggregator_arn
  local prd_hub_managed=false
  for region in "$AWS_REGION" "$DEV_REGION"; do
    if [[ "$region" == "$AWS_REGION" ]]; then
      prefix='prd'
    else
      prefix='dev'
    fi
    detector_address="module.${prefix}_threat_detection.aws_guardduty_detector.this"
    recorder_address="module.${prefix}_config.aws_config_configuration_recorder.this"
    channel_address="module.${prefix}_config.aws_config_delivery_channel.this"
    hub_address="module.${prefix}_threat_detection.aws_securityhub_account.this"
    session_document_address="module.${prefix}_session_manager.aws_ssm_document.session_preferences"

    if ! grep -Fqx "$detector_address" <<<"$state_entries"; then
      detector_count="$(aws guardduty list-detectors --region "$region" --query 'length(DetectorIds)' --output text)" || { fail "Unable to inspect GuardDuty in $region."; return 1; }
      [[ "${detector_count:-0}" == "0" ]] || { fail "GuardDuty is already enabled in $region. Import that detector before deployment."; return 1; }
    fi

    if ! grep -Fqx "$recorder_address" <<<"$state_entries"; then
      recorder_count="$(aws configservice describe-configuration-recorders --region "$region" --query 'length(ConfigurationRecorders)' --output text)" || { fail "Unable to inspect AWS Config recorders in $region."; return 1; }
      [[ "${recorder_count:-0}" == "0" ]] || { fail "A customer-managed AWS Config recorder already exists in $region. Import it before deployment."; return 1; }
    fi

    if ! grep -Fqx "$channel_address" <<<"$state_entries"; then
      channel_count="$(aws configservice describe-delivery-channels --region "$region" --query 'length(DeliveryChannels)' --output text)" || { fail "Unable to inspect AWS Config delivery channels in $region."; return 1; }
      [[ "${channel_count:-0}" == "0" ]] || { fail "An AWS Config delivery channel already exists in $region. Import it before deployment."; return 1; }
    fi

    if ! grep -Fqx "$hub_address" <<<"$state_entries"; then
      hub_error_file="$(mktemp)" || return 1
      if ! hub_arn="$(aws securityhub describe-hub --region "$region" --query 'HubArn' --output text 2>"$hub_error_file")"; then
        if ! grep -Eq '\((InvalidAccessException|ResourceNotFoundException)\)' "$hub_error_file"; then
          fail "Unable to inspect Security Hub in $region."
          sed 's/^/  /' "$hub_error_file" >&2
          rm -f "$hub_error_file"
          return 1
        fi
        hub_arn=''
      fi
      rm -f "$hub_error_file"
      [[ -z "$hub_arn" || "$hub_arn" == "None" ]] || { fail "Security Hub is already enabled in $region. Import the existing hub before deployment."; return 1; }
    elif [[ "$prefix" == 'prd' ]]; then
      prd_hub_managed=true
    fi

    if ! grep -Fqx "$session_document_address" <<<"$state_entries"; then
      document_count="$(aws ssm list-documents --region "$region" --filters 'Key=Owner,Values=Self' 'Key=Name,Values=SSM-SessionManagerRunShell' --query 'length(DocumentIdentifiers)' --output text)" || { fail "Unable to inspect Session Manager preferences in $region."; return 1; }
      [[ "${document_count:-0}" == '0' ]] || { fail "Account-level Session Manager preferences already exist in $region. Import the SSM-SessionManagerRunShell document before deployment."; return 1; }
    fi
  done

  if ! grep -Fqx 'module.audit.aws_cloudtrail.this' <<<"$state_entries"; then
    trail_count="$(aws cloudtrail describe-trails --trail-name-list 'kwu-prd-vpc-audit' --no-include-shadow-trails --query 'length(trailList)' --output text)" || { fail 'Unable to inspect existing CloudTrail trails.'; return 1; }
    [[ "${trail_count:-0}" == "0" ]] || { fail 'The CloudTrail trail kwu-prd-vpc-audit already exists. Import it before deployment.'; return 1; }
  fi

  if ! grep -Fqx 'module.prd_threat_detection.aws_securityhub_finding_aggregator.this[0]' <<<"$state_entries" && [[ "$prd_hub_managed" == true ]]; then
    aggregator_arn="$(aws securityhub list-finding-aggregators --region "$AWS_REGION" --query 'FindingAggregators[0].FindingAggregatorArn' --output text)" || { fail 'Unable to inspect Security Hub finding aggregators.'; return 1; }
    [[ -z "$aggregator_arn" || "$aggregator_arn" == "None" ]] || { fail 'A Security Hub finding aggregator already exists. Import it before deployment.'; return 1; }
  fi
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
  cat > "$RUNTIME_DIR/terraform.tfvars.json" <<EOF
{
  "aws_region": "$AWS_REGION",
  "dev_region": "$DEV_REGION",
  "domain_name": "$DOMAIN_NAME"
}
EOF
}

terraform_state_exists() {
  aws s3api head-object \
    --bucket "$BACKEND_BUCKET" \
    --key "$(state_key)" >/dev/null 2>&1
}

create_infrastructure() {
  local plan_file
  banner
  prompt_domain || return 0
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
  assert_security_services_unused "$state_entries" || return 1
  write_variables || return 1
  plan_file="$RUNTIME_DIR/create.tfplan"
  rm -f "$plan_file"
  say INFO 'Preparing a Terraform execution plan.'
  "$TERRAFORM_BIN" -chdir="$TF_DIR" plan -input=false -out="$plan_file" -var-file="$RUNTIME_DIR/terraform.tfvars.json" | tee -a "$LOG_FILE" || { rm -f "$plan_file"; return 1; }
  say INFO 'Creating infrastructure from the saved Terraform plan. Multi-AZ RDS, NAT Gateways, ACM validation, security services, PCX, and VPN activation can take several minutes.'
  "$TERRAFORM_BIN" -chdir="$TF_DIR" apply -input=false "$plan_file" | tee -a "$LOG_FILE" || { rm -f "$plan_file"; return 1; }
  rm -f "$plan_file"
  say OK 'Deployment completed. Run menu options 3, 4, and 5 in a new session to verify the application, PCX, and VPN.'
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
  say WARN 'Deletion also removes project-managed GuardDuty findings, Config history, Flow Logs, WAF logs, and CloudTrail audit objects.'
  read -r -p "Destroy all Terraform-managed infrastructure and audit data for $DOMAIN_NAME? [y/N]: " answer
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

ssm_run_shell() {
  local instance_id="$1" region="$2" command="$3" description="$4"
  local command_id status stdout stderr parameters attempt

  parameters="$(jq -cn --arg command "$command" '{commands:[$command]}')" || return 1
  command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "$instance_id" \
    --document-name 'AWS-RunShellScript' \
    --comment "$description" \
    --parameters "$parameters" \
    --query 'Command.CommandId' \
    --output text 2>/dev/null)" || { fail "Unable to send an SSM command to $instance_id in $region."; return 1; }

  status='Pending'
  for attempt in {1..60}; do
    status="$(aws ssm get-command-invocation --region "$region" --command-id "$command_id" --instance-id "$instance_id" --query 'Status' --output text 2>/dev/null || true)"
    case "$status" in
      Success|Cancelled|Failed|TimedOut|Cancelling) break ;;
      *) sleep 5 ;;
    esac
  done
  status="$(aws ssm get-command-invocation --region "$region" --command-id "$command_id" --instance-id "$instance_id" --query 'Status' --output text 2>/dev/null || true)"
  stdout="$(aws ssm get-command-invocation --region "$region" --command-id "$command_id" --instance-id "$instance_id" --query 'StandardOutputContent' --output text 2>/dev/null || true)"
  stderr="$(aws ssm get-command-invocation --region "$region" --command-id "$command_id" --instance-id "$instance_id" --query 'StandardErrorContent' --output text 2>/dev/null || true)"

  if [[ "$status" != "Success" ]]; then
    fail "SSM command failed on $instance_id. Status: ${status:-unknown}"
    [[ -z "$stdout" || "$stdout" == "None" ]] || printf '%s\n' "$stdout"
    [[ -z "$stderr" || "$stderr" == "None" ]] || printf '%s\n' "$stderr" >&2
    return 1
  fi

  [[ -z "$stdout" || "$stdout" == "None" ]] || printf '%s\n' "$stdout"
}

managed_instance_online() {
  local instance_id="$1" region="$2" status attempt
  for attempt in {1..30}; do
    status="$(aws ssm describe-instance-information \
      --region "$region" \
      --filters "Key=InstanceIds,Values=$instance_id" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || true)"
    [[ "$status" == "Online" ]] && return 0
    sleep 10
  done
  return 1
}

ensure_session_manager_plugin() {
  command -v session-manager-plugin >/dev/null 2>&1 && return 0

  local architecture package_arch package_url
  architecture="$(uname -m)"
  case "$architecture" in
    x86_64) package_arch='linux_64bit' ;;
    aarch64|arm64) package_arch='linux_arm64' ;;
    *) fail "Unsupported CloudShell CPU architecture for the Session Manager plugin: $architecture"; return 1 ;;
  esac

  require_command sudo || return 1
  package_url="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${package_arch}/session-manager-plugin.rpm"
  say INFO 'Session Manager plugin was not found. Installing the AWS-signed package.'
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y "$package_url" >/dev/null || return 1
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y "$package_url" >/dev/null || return 1
  else
    fail 'Neither dnf nor yum is available to install the Session Manager plugin.'
    return 1
  fi
  command -v session-manager-plugin >/dev/null 2>&1 || { fail 'Session Manager plugin installation did not place the executable on PATH.'; return 1; }
  say OK "Installed Session Manager plugin: $(session-manager-plugin --version 2>/dev/null || printf 'version unavailable')"
}

test_peering() {
  local pcx_id status prd_routes dev_routes dev_ips dev_nginx_ip dev_tomcat_ip dev_db_ip management_instance_id target
  banner
  prompt_domain || return 0
  initialize_terraform || return 1

  pcx_id="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw vpc_peering_connection_id 2>/dev/null)" || { fail 'No Terraform-managed VPC Peering connection exists for this domain.'; return 1; }
  [[ -n "$pcx_id" ]] || { fail 'No Terraform-managed VPC Peering connection exists for this domain.'; return 1; }

  status="$(aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids "$pcx_id" --query 'VpcPeeringConnections[0].Status.Code' --output text 2>/dev/null || true)"
  [[ "$status" == "active" ]] || { fail "VPC Peering connection is not active. Current status: ${status:-unknown}"; return 1; }
  say OK "VPC Peering connection is active: $pcx_id"

  prd_routes="$(aws ec2 describe-route-tables --filters "Name=route.vpc-peering-connection-id,Values=$pcx_id" "Name=route.destination-cidr-block,Values=$DEV_VPC_CIDR" --query 'length(RouteTables[])' --output text)"
  [[ "$prd_routes" -ge 2 ]] || { fail "PRD route tables do not both contain $DEV_VPC_CIDR -> $pcx_id routes."; return 1; }
  say OK "PRD route tables contain $DEV_VPC_CIDR peering routes."

  dev_routes="$(aws ec2 describe-route-tables --region "$DEV_REGION" --filters "Name=route.vpc-peering-connection-id,Values=$pcx_id" "Name=route.destination-cidr-block,Values=$VPC_CIDR" --query 'length(RouteTables[])' --output text)"
  [[ "$dev_routes" -ge 2 ]] || { fail "DEV route tables do not both contain $VPC_CIDR -> $pcx_id routes."; return 1; }
  say OK "DEV route tables contain $VPC_CIDR peering routes."

  dev_ips="$($TERRAFORM_BIN -chdir="$TF_DIR" output -json dev_private_ips 2>/dev/null)" || { fail 'No Terraform-managed DEV private IP outputs exist.'; return 1; }
  dev_nginx_ip="$(jq -r '.nginx // empty' <<<"$dev_ips")"
  dev_tomcat_ip="$(jq -r '.tomcat // empty' <<<"$dev_ips")"
  dev_db_ip="$(jq -r '.db // empty' <<<"$dev_ips")"
  [[ -n "$dev_nginx_ip" && -n "$dev_tomcat_ip" && -n "$dev_db_ip" ]] || { fail 'DEV private IP outputs are incomplete.'; return 1; }
  say OK "DEV private targets are known: Nginx=$dev_nginx_ip, Tomcat=$dev_tomcat_ip, DB=$dev_db_ip"

  management_instance_id="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw management_instance_id 2>/dev/null)" || { fail 'No Terraform-managed SSM management instance exists.'; return 1; }
  managed_instance_online "$management_instance_id" "$AWS_REGION" || { fail "SSM management instance is not online: $management_instance_id"; return 1; }
  for target in "$dev_nginx_ip" "$dev_tomcat_ip" "$dev_db_ip"; do
    say INFO "Testing a private ICMP packet path from $management_instance_id to $target over PCX."
    ssm_run_shell "$management_instance_id" "$AWS_REGION" "ping -c 3 -W 3 '$target'" "PCX packet test to $target" || return 1
  done
  say OK 'PCX control-plane routes and private packet paths are working.'
}

test_vpn() {
  local vpn_id vpn_statuses vpn_test_ip vpn_test_instance_id management_instance_id management_private_ip strongswan_instance_id strongswan_eni vgw_id prd_route_count dev_route_count attempt
  banner
  prompt_domain || return 0
  initialize_terraform || return 1

  vpn_id="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw vpn_connection_id 2>/dev/null)" || { fail 'No Terraform-managed Site-to-Site VPN connection exists for this domain.'; return 1; }
  vpn_test_ip="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw vpn_test_ip 2>/dev/null)" || { fail 'No Terraform-managed StrongSwan test address exists.'; return 1; }
  vpn_test_instance_id="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw vpn_test_instance_id 2>/dev/null)" || { fail 'No Terraform-managed DEV VPN test node exists.'; return 1; }
  management_instance_id="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw management_instance_id 2>/dev/null)" || { fail 'No Terraform-managed SSM management instance exists.'; return 1; }
  management_private_ip="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw management_private_ip 2>/dev/null)" || { fail 'No Terraform-managed PRD management address exists.'; return 1; }
  strongswan_instance_id="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw strongswan_instance_id 2>/dev/null)" || { fail 'No Terraform-managed StrongSwan instance exists.'; return 1; }
  strongswan_eni="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw strongswan_network_interface_id 2>/dev/null)" || { fail 'No Terraform-managed StrongSwan network interface exists.'; return 1; }
  vgw_id="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw virtual_private_gateway_id 2>/dev/null)" || { fail 'No Terraform-managed virtual private gateway exists.'; return 1; }

  vpn_statuses=""
  for attempt in {1..90}; do
    vpn_statuses="$(aws ec2 describe-vpn-connections --region "$AWS_REGION" --vpn-connection-ids "$vpn_id" --query 'VpnConnections[0].VgwTelemetry[].Status' --output text 2>/dev/null || true)"
    [[ "$vpn_statuses" == *UP* ]] && break
    sleep 10
  done
  [[ "$vpn_statuses" == *UP* ]] || { fail "Neither AWS VPN tunnel is UP. Current statuses: ${vpn_statuses:-unknown}"; return 1; }
  say OK "At least one AWS VPN tunnel is UP: $vpn_id ($vpn_statuses)"

  prd_route_count="$(aws ec2 describe-route-tables --region "$AWS_REGION" --filters "Name=route.gateway-id,Values=$vgw_id" "Name=route.destination-cidr-block,Values=$VPN_TEST_CIDR" --query 'length(RouteTables)' --output text 2>/dev/null || true)"
  [[ "${prd_route_count:-0}" -ge 1 ]] || { fail "No PRD route sends $VPN_TEST_CIDR to $vgw_id."; return 1; }
  dev_route_count="$(aws ec2 describe-route-tables --region "$DEV_REGION" --filters "Name=route.network-interface-id,Values=$strongswan_eni" "Name=route.destination-cidr-block,Values=10.250.2.0/24" --query 'length(RouteTables)' --output text 2>/dev/null || true)"
  [[ "${dev_route_count:-0}" -ge 1 ]] || { fail "No DEV return route sends 10.250.2.0/24 to $strongswan_eni."; return 1; }
  say OK 'The dedicated forward and return routes target the VPN gateways.'

  managed_instance_online "$strongswan_instance_id" "$DEV_REGION" || { fail "StrongSwan is not online in SSM: $strongswan_instance_id"; return 1; }
  ssm_run_shell "$strongswan_instance_id" "$DEV_REGION" "ipsec statusall | grep -q ESTABLISHED && ip -brief link show | grep -E 'Tunnel1|Tunnel2'" 'StrongSwan tunnel status test' || return 1

  managed_instance_online "$management_instance_id" "$AWS_REGION" || { fail "SSM management instance is not online: $management_instance_id"; return 1; }
  say INFO "Testing encrypted ICMP traffic to StrongSwan address $vpn_test_ip in $VPN_TEST_CIDR."
  ssm_run_shell "$management_instance_id" "$AWS_REGION" "ping -c 5 -W 3 '$vpn_test_ip'" 'StrongSwan VPN packet test' || return 1
  managed_instance_online "$vpn_test_instance_id" "$DEV_REGION" || { fail "DEV VPN test node is not online in SSM: $vpn_test_instance_id"; return 1; }
  say INFO "Testing the encrypted return path from $vpn_test_ip to PRD management address $management_private_ip."
  ssm_run_shell "$vpn_test_instance_id" "$DEV_REGION" "ping -c 5 -W 3 '$management_private_ip'" 'StrongSwan VPN return-path test' || return 1
  say OK 'Both directions of the AWS Site-to-Site VPN and StrongSwan packet path are working.'
}

start_management_session() {
  local management_instance_id
  banner
  prompt_domain || return 0
  initialize_terraform || return 1
  ensure_session_manager_plugin || return 1

  management_instance_id="$($TERRAFORM_BIN -chdir="$TF_DIR" output -raw management_instance_id 2>/dev/null)" || { fail 'No Terraform-managed SSM management instance exists.'; return 1; }
  managed_instance_online "$management_instance_id" "$AWS_REGION" || { fail "SSM management instance is not online: $management_instance_id"; return 1; }
  say INFO "Starting an audited Session Manager shell on $management_instance_id. Type exit to return to the menu."
  aws ssm start-session --region "$AWS_REGION" --target "$management_instance_id"
}

draw_menu() {
  banner
  printf '1) Create infrastructure\n'
  printf '2) Delete all infrastructure\n'
  printf '3) Test ALB and application connectivity\n'
  printf '4) Test VPC Peering connectivity\n'
  printf '5) Test StrongSwan VPN connectivity\n'
  printf '6) Start SSM management session\n'
  printf '7) Exit\n\n'
}

main() {
  init_log
  while true; do
    draw_menu
    read -r -p 'Select an option [1-7]: ' choice || choice=7
    choice="${choice%$'\r'}"
    case "$choice" in
      1) if create_infrastructure; then say INFO 'Creation completed. Exiting.'; return 0; else say ERROR 'Creation failed. No further deployment steps were run.'; fi ;;
      2) if ! delete_infrastructure; then say ERROR 'Deletion failed. Check the log before retrying.'; fi ;;
      3) if ! test_application true; then say ERROR 'Connectivity test failed.'; fi ;;
      4) if ! test_peering; then say ERROR 'VPC Peering connectivity test failed.'; fi ;;
      5) if ! test_vpn; then say ERROR 'StrongSwan VPN connectivity test failed.'; fi ;;
      6) if ! start_management_session; then say ERROR 'Unable to start the SSM management session.'; fi ;;
      7) say INFO 'Exiting.'; return 0 ;;
      *) say ERROR 'Invalid selection. Enter a number from 1 to 7.' ;;
    esac
    printf '\nPress Enter to continue...'
    read -r _ || true
  done
}
