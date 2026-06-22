#!/usr/bin/env bash

set -u
set -o pipefail

export AWS_PAGER=""
export AWS_DEFAULT_OUTPUT="text"

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

VPC_NAME="KWU-PRD-VPC"
VPC_CIDR="10.250.0.0/16"
AMI_ID="ami-0765f9741eedf9c7b"
INSTANCE_TYPE="t3.micro"
INSTANCE_COUNT=1
KEY_NAME="kwuaws"
ANYWHERE="0.0.0.0/0"
ADMIN_CIDR="${ADMIN_CIDR:-0.0.0.0/0}"
APPLICATION_LOAD_BALANCER_NAME="KWU-PRD-VPC-ALB"
TARGET_GROUP_NAME="KWU-PRD-VPC-NGINX-TG"
DB_INSTANCE_IDENTIFIER="kwu-prd-vpc-mysql"
DB_NAME="appdb"
DB_MASTER_USERNAME="appadmin"
DB_SUBNET_GROUP_NAME="kwu-prd-vpc-db-subnets"

RETRY_MAX_ATTEMPTS=3
RETRY_DELAY_SECONDS=2
HTTP_VERIFY_ATTEMPTS=60
HTTP_VERIFY_DELAY_SECONDS=5
DELETE_POLL_ATTEMPTS=40
DELETE_POLL_DELAY_SECONDS=5

LOG_FILE=""
CURRENT_STAGE="Idle"
LAST_ERROR=""
LAST_COMMAND_OUTPUT=""
CREATE_ACTIVE=0
CREATE_INTERRUPTED=0
CURRENT_VPC_ID=""
DOMAIN_NAME=""
ROUTE53_HOSTED_ZONE_ID=""
ALB_ARN=""
ALB_DNS_NAME=""
ALB_HOSTED_ZONE_ID=""
ALB_ALIAS_DNS_NAME=""
TARGET_GROUP_ARN=""
DB_ENDPOINT=""
DELETE_FAILURES=()
PROGRESS_TOTAL=0
PROGRESS_COMPLETED=0
PROGRESS_ACTION=""
PROGRESS_INLINE=0

COLOR_RESET=""
COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_BLUE=""
COLOR_BOLD=""

init_colors() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        COLOR_RESET=$'\033[0m'
        COLOR_RED=$'\033[31m'
        COLOR_GREEN=$'\033[32m'
        COLOR_YELLOW=$'\033[33m'
        COLOR_BLUE=$'\033[34m'
        COLOR_BOLD=$'\033[1m'
    fi
}

init_logging() {
    local output_dir="${AUTO_INFRA_OUTPUT_DIR:-./outputs}"
    mkdir -p "$output_dir" || {
        printf 'ERROR: Unable to create log directory: %s\n' "$output_dir" >&2
        return 1
    }
    LOG_FILE="$output_dir/auto_infra_$(date '+%Y%m%d_%H%M%S').log"
    : >"$LOG_FILE" || {
        printf 'ERROR: Unable to create log file: %s\n' "$LOG_FILE" >&2
        return 1
    }
}

log_line() {
    local level="$1"
    shift
    local message="$*"

    if [[ -n "$LOG_FILE" ]]; then
        printf '%s [%s] [%s] %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$CURRENT_STAGE" "$message" \
            >>"$LOG_FILE"
    fi
}

print_event() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    local color=""

    timestamp="$(date '+%H:%M:%S')"
    case "$level" in
        OK|DONE)
            color="$COLOR_GREEN"
            ;;
        WARN|SKIPPED)
            color="$COLOR_YELLOW"
            ;;
        ERROR|FAILED)
            color="$COLOR_RED"
            ;;
        INFO|RUNNING)
            color="$COLOR_BLUE"
            ;;
    esac

    if (( PROGRESS_INLINE == 1 )); then
        printf '\n'
        PROGRESS_INLINE=0
    fi
    printf '%s  %s%-7s%s %s\n' \
        "$timestamp" "$color" "$level" "$COLOR_RESET" "$message"
    log_line "$level" "$message"
}

print_info() {
    print_event "INFO" "$*"
}

print_success() {
    print_event "OK" "$*"
}

print_warning() {
    print_event "WARN" "$*"
}

print_error() {
    print_event "ERROR" "$*" >&2
}

progress_is_interactive() {
    [[ -t 1 && -z "${NO_COLOR:-}" ]]
}

render_progress() {
    local completed="${1:-0}"
    local total="${2:-0}"
    local status="${3:-RUNNING}"
    local message="${4:-}"
    local percent=0
    local filled=0
    local empty=20
    local filled_bar=""
    local empty_bar=""
    local output=""
    local color=""

    if [[ ! "$completed" =~ ^[0-9]+$ ]]; then
        completed=0
    fi
    if [[ ! "$total" =~ ^[0-9]+$ ]]; then
        total=0
    fi
    if (( total > 0 )); then
        if (( completed > total )); then
            completed="$total"
        fi
        percent=$((completed * 100 / total))
    fi

    filled=$((percent * 20 / 100))
    empty=$((20 - filled))
    printf -v filled_bar '%*s' "$filled" ''
    printf -v empty_bar '%*s' "$empty" ''
    filled_bar="${filled_bar// /#}"
    empty_bar="${empty_bar// /-}"

    case "$status" in
        DONE)
            color="$COLOR_GREEN"
            ;;
        SKIPPED)
            color="$COLOR_YELLOW"
            ;;
        FAILED)
            color="$COLOR_RED"
            ;;
        *)
            status="RUNNING"
            color="$COLOR_BLUE"
            ;;
    esac

    printf -v output '[%s%s] %3d%% %s%s%s %s' \
        "$filled_bar" "$empty_bar" "$percent" \
        "$color" "$status" "$COLOR_RESET" "$message"

    if progress_is_interactive && [[ -z "${NO_COLOR:-}" ]]; then
        printf '\r%-100s' "$output"
        if [[ "$status" == "RUNNING" ]]; then
            PROGRESS_INLINE=1
        else
            printf '\n'
            PROGRESS_INLINE=0
        fi
    else
        printf '%s\n' "$output"
        PROGRESS_INLINE=0
    fi
}

init_progress() {
    local total="${1:-0}"

    if [[ ! "$total" =~ ^[0-9]+$ ]]; then
        total=0
    fi
    PROGRESS_TOTAL="$total"
    PROGRESS_COMPLETED=0
    PROGRESS_ACTION="${2:-Operation}"
    render_progress "$PROGRESS_COMPLETED" "$PROGRESS_TOTAL" \
        "RUNNING" "$PROGRESS_ACTION"
}

advance_progress() {
    local status="${1:-RUNNING}"
    local message="${2:-$PROGRESS_ACTION}"

    if [[ "$status" != "FAILED" && $PROGRESS_COMPLETED -lt $PROGRESS_TOTAL ]]; then
        PROGRESS_COMPLETED=$((PROGRESS_COMPLETED + 1))
    fi
    render_progress "$PROGRESS_COMPLETED" "$PROGRESS_TOTAL" "$status" "$message"
}

show_logo() {
    cat <<'AUTO_INFRA_LOGO'
   ___      _____   ___ _  _ ___ ___    _       _  _   _ _____ ___
  /_\ \    / / __| |_ _| \| | __| _ \  /_\     /_\| | | |_   _/ _ \
 / _ \ \/\/ /\__ \  | || .` | _||   / / _ \   / _ \ |_| | | || (_) |
/_/ \_\_/\_/ |___/ |___|_|\_|_| |_|_\/_/ \_\ /_/ \_\___/  |_| \___/
AUTO_INFRA_LOGO
}

set_stage() {
    if (( PROGRESS_INLINE == 1 )); then
        printf '\n'
        PROGRESS_INLINE=0
    fi
    CURRENT_STAGE="$1"
    printf '\n%s== %s ==%s\n' "$COLOR_BOLD" "$CURRENT_STAGE" "$COLOR_RESET"
    log_line "STAGE" "$CURRENT_STAGE"
}

confirm() {
    local prompt="$1"
    local answer

    while true; do
        printf '%s [y/N]: ' "$prompt"
        if ! IFS= read -r answer; then
            return 1
        fi
        case "$answer" in
            y|Y|yes|YES|Yes)
                return 0
                ;;
            ""|n|N|no|NO|No)
                return 1
                ;;
            *)
                print_error "Enter y or n."
                ;;
        esac
    done
}

normalize_domain() {
    local LC_ALL=C
    local domain="${1:-}"

    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    domain="${domain,,}"
    if [[ "$domain" != *.. ]]; then
        domain="${domain%.}"
    fi
    printf '%s\n' "$domain"
}

validate_domain() {
    local LC_ALL=C
    local domain
    local label
    local labels=()

    domain="$(normalize_domain "${1:-}")"
    if [[ -z "$domain" || ${#domain} -gt 253 ]]; then
        return 1
    fi
    if [[ "$domain" != *.* || "$domain" =~ [^a-z0-9.-] ]]; then
        return 1
    fi

    IFS='.' read -r -a labels <<<"$domain"
    if (( ${#labels[@]} < 2 )); then
        return 1
    fi
    for label in "${labels[@]}"; do
        if [[ -z "$label" || ${#label} -gt 63 ]]; then
            return 1
        fi
        if [[ ! "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
            return 1
        fi
    done
}

prompt_domain() {
    local input
    local normalized

    while true; do
        printf 'Enter the domain name: '
        if ! IFS= read -r input; then
            print_error "Domain input ended before a valid value was provided."
            return 1
        fi

        normalized="$(normalize_domain "$input")"
        if validate_domain "$normalized"; then
            DOMAIN_NAME="$normalized"
            print_success "Domain accepted: $DOMAIN_NAME"
            return 0
        fi
        print_error "Invalid domain name."
    done
}

fqdn_with_dot() {
    local domain

    domain="$(normalize_domain "${1:-}")"
    if [[ -z "$domain" ]]; then
        return 1
    fi
    printf '%s.\n' "${domain%.}"
}

strip_route53_hosted_zone_prefix() {
    local hosted_zone_id="${1:-}"

    hosted_zone_id="${hosted_zone_id##*/}"
    printf '%s\n' "$hosted_zone_id"
}

find_route53_hosted_zone_for_domain() {
    local result_variable="$1"
    local domain
    local candidate
    local dns_name
    local hosted_zone_id=""

    domain="$(normalize_domain "${2:-}")"
    if ! validate_domain "$domain"; then
        LAST_ERROR="Invalid domain name for Route 53 lookup: $domain"
        print_error "$LAST_ERROR"
        return 1
    fi

    candidate="$domain"
    while [[ "$candidate" == *.* ]]; do
        dns_name="$(fqdn_with_dot "$candidate")"
        if ! aws_query hosted_zone_id "Find Route 53 hosted zone for $candidate" \
            route53 list-hosted-zones-by-name \
            --dns-name "$dns_name" \
            --query "HostedZones[?Name=='$dns_name' && Config.PrivateZone==\`false\`].Id | [0]" \
            --output text; then
            return 1
        fi

        if [[ -n "$hosted_zone_id" && "$hosted_zone_id" != "None" ]]; then
            hosted_zone_id="$(strip_route53_hosted_zone_prefix "$hosted_zone_id")"
            printf -v "$result_variable" '%s' "$hosted_zone_id"
            return 0
        fi

        candidate="${candidate#*.}"
    done

    LAST_ERROR="No public Route 53 hosted zone was found for $domain or its parent domains."
    print_error "$LAST_ERROR"
    return 1
}

build_route53_alias_change_batch() {
    local action="$1"
    local record_name="$2"
    local alias_dns_name="$3"
    local alias_hosted_zone_id="$4"

    cat <<JSON
{
  "Comment": "Auto Infra Application Load Balancer alias record",
  "Changes": [
    {
      "Action": "$action",
      "ResourceRecordSet": {
        "Name": "$record_name",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "$alias_hosted_zone_id",
          "DNSName": "$alias_dns_name",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
JSON
}

make_temp_file() {
    mktemp "${TMPDIR:-/tmp}/auto-infra.XXXXXX"
}

run_with_retry() {
    local description="$1"
    shift
    local attempt=1
    local status=0
    local temp_file

    temp_file="$(make_temp_file)" || {
        LAST_ERROR="Unable to create a temporary command output file."
        return 1
    }

    while (( attempt <= RETRY_MAX_ATTEMPTS )); do
        if (( CREATE_INTERRUPTED == 1 && CREATE_ACTIVE == 1 )); then
            LAST_ERROR="Creation interrupted by the user."
            rm -f "$temp_file"
            return 130
        fi
        : >"$temp_file"
        log_line "COMMAND" "$description (attempt $attempt)"

        if "$@" >"$temp_file" 2>&1; then
            LAST_COMMAND_OUTPUT="$(<"$temp_file")"
            if [[ -n "$LAST_COMMAND_OUTPUT" ]]; then
                log_line "OUTPUT" "$LAST_COMMAND_OUTPUT"
            fi
            rm -f "$temp_file"
            return 0
        else
            status=$?
        fi

        LAST_COMMAND_OUTPUT="$(<"$temp_file")"
        LAST_ERROR="$description failed with exit status $status"
        log_line "ERROR" "$LAST_ERROR: $LAST_COMMAND_OUTPUT"

        if (( attempt < RETRY_MAX_ATTEMPTS )) && is_retryable_error "$LAST_COMMAND_OUTPUT"; then
            if (( CREATE_INTERRUPTED == 1 )); then
                break
            fi
            print_warning "$description failed. Retrying ($attempt/$RETRY_MAX_ATTEMPTS)."
            sleep "$((RETRY_DELAY_SECONDS * attempt))"
        else
            break
        fi
        attempt=$((attempt + 1))
    done

    rm -f "$temp_file"
    print_error "$LAST_ERROR"
    if [[ -n "$LAST_COMMAND_OUTPUT" ]]; then
        print_error "$LAST_COMMAND_OUTPUT"
    fi
    return "$status"
}

is_retryable_error() {
    local error_text="$1"

    case "$error_text" in
        *Throttling*|*RequestLimitExceeded*|*TooManyRequestsException*|\
        *ServiceUnavailable*|*DependencyViolation*|*ResourceInUse*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

capture_with_retry() {
    local result_variable="$1"
    local description="$2"
    shift 2

    if ! run_with_retry "$description" "$@"; then
        return 1
    fi
    printf -v "$result_variable" '%s' "$LAST_COMMAND_OUTPUT"
}

aws_query() {
    local result_variable="$1"
    local description="$2"
    shift 2
    capture_with_retry "$result_variable" "$description" aws "$@"
}

aws_mutate() {
    local description="$1"
    shift
    run_with_retry "$description" aws "$@"
}

render_nginx_html() {
    local zone="$1"
    local identifier
    local bg_color
    local card_bg
    local card_border
    local accent_color
    local accent_glow
    local text_main
    local text_dim
    local success_bg
    local matrix_fade

    case "$zone" in
        2A)
            identifier="KWU-PRD-VPC-NGINX-PUB-2A"
            bg_color="#030712"
            card_bg="rgba(15, 23, 42, 0.65)"
            card_border="rgba(56, 189, 248, 0.2)"
            accent_color="#38bdf8"
            accent_glow="rgba(56, 189, 248, 0.4)"
            text_main="#f9fafb"
            text_dim="#9ca3af"
            success_bg="rgba(56, 189, 248, 0.12)"
            matrix_fade="rgba(3, 7, 18, 0.08)"
            ;;
        2C)
            identifier="KWU-PRD-VPC-NGINX-PUB-2C"
            bg_color="#090202"
            card_bg="rgba(24, 9, 9, 0.65)"
            card_border="rgba(248, 113, 113, 0.2)"
            accent_color="#f87171"
            accent_glow="rgba(248, 113, 113, 0.4)"
            text_main="#fef2f2"
            text_dim="#fca5a5"
            success_bg="rgba(248, 113, 113, 0.12)"
            matrix_fade="rgba(9, 2, 2, 0.08)"
            ;;
        *)
            print_error "Unknown Nginx zone: $zone"
            return 1
            ;;
    esac

    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AR0NICA | Service Operational</title>
    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Ccircle cx='50' cy='50' r='35' stroke='%2338bdf8' stroke-width='10' fill='none'/%3E%3Cline x1='20' y1='80' x2='80' y2='20' stroke='%2338bdf8' stroke-width='10' stroke-linecap='round'/%3E%3C/svg%3E">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-color: $bg_color;
            --card-bg: $card_bg;
            --card-border: $card_border;
            --accent-color: $accent_color;
            --accent-glow: $accent_glow;
            --text-main: $text_main;
            --text-dim: $text_dim;
            --success-bg: $success_bg;
        }
        body {
            margin: 0;
            padding: 0;
            font-family: Inter, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-main);
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            overflow: hidden;
            position: relative;
        }
        #matrix-canvas {
            position: absolute;
            inset: 0;
            width: 100%;
            height: 100%;
            z-index: -1;
            opacity: 0.25;
            pointer-events: none;
        }
        .container {
            text-align: center;
            padding: 3rem 2.5rem;
            background: var(--card-bg);
            backdrop-filter: blur(16px);
            border-radius: 24px;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.7);
            border: 1px solid var(--card-border);
            max-width: 460px;
            width: 85%;
            animation: fadeIn 1.2s cubic-bezier(0.16, 1, 0.3, 1);
        }
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(30px); }
            to { opacity: 1; transform: translateY(0); }
        }
        .status-badge {
            display: inline-flex;
            align-items: center;
            background: var(--success-bg);
            color: var(--accent-color);
            padding: 8px 16px;
            border-radius: 99px;
            font-size: 0.8rem;
            font-weight: 600;
            letter-spacing: 0.05em;
            text-transform: uppercase;
            margin-bottom: 2rem;
            border: 1px solid var(--card-border);
        }
        .status-dot {
            width: 8px;
            height: 8px;
            background-color: var(--accent-color);
            border-radius: 50%;
            margin-right: 10px;
            box-shadow: 0 0 12px var(--accent-color);
            animation: pulse 2.5s infinite ease-in-out;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; transform: scale(1); }
            50% { opacity: 0.4; transform: scale(0.9); }
        }
        h1 {
            font-size: 2.25rem;
            font-weight: 700;
            margin: 0 0 1rem;
            letter-spacing: -0.03em;
        }
        p {
            color: var(--text-dim);
            line-height: 1.65;
            font-size: 0.95rem;
            margin: 0 0 2.5rem;
        }
        .server-info {
            border-top: 1px solid rgba(255, 255, 255, 0.08);
            padding-top: 2rem;
        }
        .label {
            color: var(--text-dim);
            display: block;
            margin-bottom: 0.6rem;
            font-size: 0.725rem;
            text-transform: uppercase;
            letter-spacing: 0.1em;
        }
        .value {
            font-family: Consolas, "Liberation Mono", monospace;
            color: var(--accent-color);
            font-weight: 600;
            font-size: 0.95rem;
            text-shadow: 0 0 10px var(--accent-glow);
            background: var(--success-bg);
            padding: 6px 14px;
            border-radius: 8px;
            display: inline-block;
            border: 1px solid var(--card-border);
        }
    </style>
</head>
<body>
    <canvas id="matrix-canvas"></canvas>
    <div class="container">
        <div class="status-badge">
            <span class="status-dot"></span>
            Operational
        </div>
        <h1>Nginx is Working</h1>
        <p>The web server software is successfully installed and the content is being served correctly.</p>
        <div class="server-info">
            <span class="label">Server Identifier</span>
            <span class="value">$identifier</span>
        </div>
    </div>
    <script>
        const canvas = document.getElementById("matrix-canvas");
        const ctx = canvas.getContext("2d");
        const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        const fontSize = 12;
        let columns;
        let drops;
        function resizeCanvas() {
            canvas.width = window.innerWidth;
            canvas.height = window.innerHeight;
            columns = Math.ceil(canvas.width / fontSize);
            drops = Array.from({ length: columns }).fill(1);
        }
        function drawMatrix() {
            ctx.fillStyle = "$matrix_fade";
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            ctx.fillStyle = "$accent_color";
            ctx.font = "500 " + fontSize + "px monospace";
            for (let i = 0; i < drops.length; i += 1) {
                const text = letters.charAt(Math.floor(Math.random() * letters.length));
                ctx.fillText(text, i * fontSize, drops[i] * fontSize);
                if (drops[i] * fontSize > canvas.height && Math.random() > 0.98) {
                    drops[i] = 0;
                }
                drops[i] += 1;
            }
        }
        resizeCanvas();
        setInterval(drawMatrix, 30);
        window.addEventListener("resize", resizeCanvas);
    </script>
</body>
</html>
HTML
}

build_nginx_user_data() {
    local zone="$1"
    local html

    html="$(render_nginx_html "$zone")" || return 1
    cat <<USERDATA
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx
cat > /var/www/html/index.html <<'AUTO_INFRA_HTML'
$html
AUTO_INFRA_HTML
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/conf.d/tomcat-proxy.conf <<'AUTO_INFRA_NGINX'
upstream tomcat_backend {
    least_conn;
    server 10.250.2.240:8080 max_fails=3 fail_timeout=10s;
    server 10.250.12.240:8080 max_fails=3 fail_timeout=10s;
}

server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
    index index.html;

    location /app/ {
        proxy_pass http://tomcat_backend/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
AUTO_INFRA_NGINX
systemctl enable nginx
systemctl restart nginx
touch /var/lib/cloud/instance/auto-infra-nginx-complete
USERDATA
}

build_tomcat_user_data() {
    local zone="$1"
    local db_endpoint="$2"

    cat <<USERDATA
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openjdk-17-jdk tomcat9
rm -f /var/lib/tomcat9/webapps/ROOT/index.html
cat > /var/lib/tomcat9/webapps/ROOT/index.jsp <<'AUTO_INFRA_JSP'
<%@ page contentType="text/html; charset=UTF-8" %>
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>3-Tier Application</title></head>
<body>
  <h1>Tomcat WAS is working</h1>
  <p>Application server: <strong>KWU-PRD-VPC-TOMCAT-PRI-$zone</strong></p>
  <p>Request path: <strong><%= request.getRequestURI() %></strong></p>
  <p>Database endpoint: <strong>$db_endpoint</strong></p>
  <p>RDS is private and its managed master secret is not copied to this instance.</p>
</body>
</html>
AUTO_INFRA_JSP
chown tomcat:tomcat /var/lib/tomcat9/webapps/ROOT/index.jsp
systemctl enable tomcat9
systemctl restart tomcat9
touch /var/lib/cloud/instance/auto-infra-tomcat-complete
USERDATA
}

find_vpc_ids() {
    local result_variable="${1:-}"
    local found_vpc_ids=""

    if ! aws_query found_vpc_ids "Find VPCs named $VPC_NAME" \
        ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=$VPC_NAME" \
        --query 'Vpcs[].VpcId' \
        --output text; then
        return 1
    fi

    if [[ -n "$result_variable" ]]; then
        local -n result_reference="$result_variable"
        result_reference="$found_vpc_ids"
    else
        printf '%s\n' "$found_vpc_ids"
    fi
}

read_vpc_domain() {
    local __auto_infra_output_name="$1"
    local __auto_infra_vpc_id="$2"
    local __auto_infra_tag_value=""
    local __auto_infra_normalized_domain=""

    if ! aws_query __auto_infra_tag_value "Read domain from VPC $__auto_infra_vpc_id" \
        ec2 describe-vpcs \
        --vpc-ids "$__auto_infra_vpc_id" \
        --query 'Vpcs[0].Tags[?Key==`AutoInfraDomain`].Value | [0]' \
        --output text; then
        return 1
    fi

    if [[ -z "$__auto_infra_tag_value" || "$__auto_infra_tag_value" == "None" ]]; then
        printf -v "$__auto_infra_output_name" '%s' ""
        return 0
    fi

    __auto_infra_normalized_domain="$(normalize_domain "$__auto_infra_tag_value")"
    if ! validate_domain "$__auto_infra_normalized_domain"; then
        printf -v "$__auto_infra_output_name" '%s' ""
        print_warning "Ignoring invalid AutoInfraDomain tag on VPC $__auto_infra_vpc_id."
        return 0
    fi

    printf -v "$__auto_infra_output_name" '%s' "$__auto_infra_normalized_domain"
}

check_prerequisites() {
    local account_id=""
    local key_name=""
    local image_state=""

    set_stage "Prerequisite checks"

    local required_command
    for required_command in aws curl base64; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            LAST_ERROR="Required command not found: $required_command"
            print_error "$LAST_ERROR"
            return 1
        fi
    done

    if ! aws_query account_id "Validate AWS credentials" \
        sts get-caller-identity --query 'Account' --output text; then
        return 1
    fi
    print_success "AWS credentials are valid for account $account_id."

    if ! aws_query key_name "Validate EC2 key pair" \
        ec2 describe-key-pairs \
        --key-names "$KEY_NAME" \
        --query 'KeyPairs[0].KeyName' \
        --output text; then
        return 1
    fi
    if [[ "$key_name" != "$KEY_NAME" ]]; then
        LAST_ERROR="EC2 key pair not found in $AWS_REGION: $KEY_NAME"
        print_error "$LAST_ERROR"
        return 1
    fi
    print_success "EC2 key pair is available: $KEY_NAME"

    if ! aws_query image_state "Validate EC2 AMI" \
        ec2 describe-images \
        --image-ids "$AMI_ID" \
        --query 'Images[0].State' \
        --output text; then
        return 1
    fi
    if [[ "$image_state" != "available" ]]; then
        LAST_ERROR="AMI is not available in $AWS_REGION: $AMI_ID"
        print_error "$LAST_ERROR"
        return 1
    fi
    print_success "AMI is available: $AMI_ID"

    if ! find_route53_hosted_zone_for_domain ROUTE53_HOSTED_ZONE_ID "$DOMAIN_NAME"; then
        return 1
    fi
    print_success "Route 53 hosted zone is available: $ROUTE53_HOSTED_ZONE_ID"

    if ! validate_ec2_launch_cli_model; then
        return 1
    fi
    print_success "EC2 launch arguments are supported by the local AWS CLI."
}

record_delete_failure() {
    local operation="$1"
    DELETE_FAILURES+=("$operation")
    print_error "Cleanup operation failed: $operation"
}

best_effort_aws() {
    local description="$1"
    shift

    if ! aws_mutate "$description" "$@"; then
        record_delete_failure "$description"
        return 1
    fi
}

safe_query() {
    local result_variable="$1"
    local description="$2"
    shift 2
    local result=""

    if aws_query result "$description" "$@"; then
        [[ "$result" == "None" ]] && result=""
        printf -v "$result_variable" '%s' "$result"
        return 0
    fi

    record_delete_failure "$description"
    printf -v "$result_variable" '%s' ""
    return 1
}

delete_named_load_balancers() {
    local vpc_id="$1"
    local alb_arns=""
    local target_group_arns=""
    local arn

    safe_query alb_arns "Find application load balancers" \
        elbv2 describe-load-balancers \
        --query "LoadBalancers[?VpcId=='$vpc_id'].LoadBalancerArn" \
        --output text || true
    for arn in $alb_arns; do
        best_effort_aws "Delete application load balancer $arn" \
            elbv2 delete-load-balancer --load-balancer-arn "$arn" || true
    done
    if [[ -n "$alb_arns" ]]; then
        best_effort_aws "Wait for application load balancers to delete" \
            elbv2 wait load-balancers-deleted --load-balancer-arns $alb_arns || true
    fi
    safe_query target_group_arns "Find ALB target groups" \
        elbv2 describe-target-groups \
        --query "TargetGroups[?VpcId=='$vpc_id'].TargetGroupArn" \
        --output text || true
    for arn in $target_group_arns; do
        best_effort_aws "Delete ALB target group $arn" \
            elbv2 delete-target-group --target-group-arn "$arn" || true
    done

}

delete_route53_alias_record_for_vpc() {
    local vpc_id="$1"
    local domain=""
    local hosted_zone_id=""
    local alb_arns=""
    local alb_arn
    local alb_dns_name=""
    local alb_hosted_zone_id=""
    local alias_dns_name=""
    local record_name=""
    local change_batch=""
    local change_id=""
    local temp_file
    local status=0

    if ! read_vpc_domain domain "$vpc_id"; then
        record_delete_failure "Read domain tag for $vpc_id"
        return 1
    fi
    if [[ -z "$domain" ]]; then
        print_warning "No domain tag found for $vpc_id. Skipping DNS cleanup."
        return 0
    fi
    if ! find_route53_hosted_zone_for_domain hosted_zone_id "$domain"; then
        print_warning "Route 53 hosted zone was not found for $domain. Skipping DNS cleanup."
        return 0
    fi

    safe_query alb_arns "Find application load balancers for DNS cleanup" \
        elbv2 describe-load-balancers \
        --query "LoadBalancers[?VpcId=='$vpc_id' && Type=='application'].LoadBalancerArn" \
        --output text || true
    if [[ -z "$alb_arns" ]]; then
        print_warning "No application load balancer found for DNS cleanup."
        return 0
    fi

    record_name="$(fqdn_with_dot "$domain")"
    for alb_arn in $alb_arns; do
        safe_query alb_dns_name "Read DNS name for application load balancer $alb_arn" \
            elbv2 describe-load-balancers --load-balancer-arns "$alb_arn" \
            --query 'LoadBalancers[0].DNSName' \
            --output text || true
        safe_query alb_hosted_zone_id "Read hosted zone ID for application load balancer $alb_arn" \
            elbv2 describe-load-balancers --load-balancer-arns "$alb_arn" \
            --query 'LoadBalancers[0].CanonicalHostedZoneId' \
            --output text || true
        if [[ -z "$alb_dns_name" || "$alb_dns_name" == "None" || \
              -z "$alb_hosted_zone_id" || "$alb_hosted_zone_id" == "None" ]]; then
            print_warning "Skipping DNS cleanup for $alb_arn because load balancer DNS details are unavailable."
            continue
        fi

        alias_dns_name="dualstack.${alb_dns_name%.}."
        change_batch="$(build_route53_alias_change_batch DELETE \
            "$record_name" "$alias_dns_name" "$alb_hosted_zone_id")"
        temp_file="$(make_temp_file)" || {
            record_delete_failure "Create temporary file for DNS cleanup"
            return 1
        }

        if aws route53 change-resource-record-sets \
            --hosted-zone-id "$hosted_zone_id" \
            --change-batch "$change_batch" \
            --query 'ChangeInfo.Id' \
            --output text >"$temp_file" 2>&1; then
            change_id="$(<"$temp_file")"
            rm -f "$temp_file"
            if [[ -n "$change_id" && "$change_id" != "None" ]]; then
                best_effort_aws "Wait for Route 53 alias deletion" \
                    route53 wait resource-record-sets-changed --id "$change_id" || true
            fi
            print_success "Deleted Route 53 alias record: $record_name"
        else
            status=$?
            LAST_COMMAND_OUTPUT="$(<"$temp_file")"
            rm -f "$temp_file"
            if [[ "$LAST_COMMAND_OUTPUT" == *"not found"* || \
                  "$LAST_COMMAND_OUTPUT" == *"was not found"* || \
                  "$LAST_COMMAND_OUTPUT" == *"Tried to delete resource record set"* ]]; then
                print_warning "Route 53 alias record was not present: $record_name"
                log_line "WARN" "Route 53 alias delete skipped: $LAST_COMMAND_OUTPUT"
            else
                LAST_ERROR="Delete Route 53 alias record failed with exit status $status"
                log_line "ERROR" "$LAST_ERROR: $LAST_COMMAND_OUTPUT"
                record_delete_failure "Delete Route 53 alias record $record_name"
            fi
        fi
    done
}

terminate_vpc_instances() {
    local vpc_id="$1"
    local instance_ids=""

    safe_query instance_ids "Find EC2 instances in $vpc_id" \
        ec2 describe-instances \
        --filters "Name=vpc-id,Values=$vpc_id" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text || true

    if [[ -n "$instance_ids" ]]; then
        best_effort_aws "Terminate EC2 instances" \
            ec2 terminate-instances --instance-ids $instance_ids || true
        best_effort_aws "Wait for EC2 instance termination" \
            ec2 wait instance-terminated --instance-ids $instance_ids || true
    fi
}

delete_rds_resources() {
    local vpc_id="$1"
    local db_instance_ids=""
    local db_subnet_group_names=""
    local db_instance_id
    local db_subnet_group_name

    safe_query db_instance_ids "Find RDS instances in $vpc_id" \
        rds describe-db-instances \
        --query "DBInstances[?DBSubnetGroup.VpcId=='$vpc_id'].DBInstanceIdentifier" \
        --output text || true
    for db_instance_id in $db_instance_ids; do
        best_effort_aws "Delete RDS instance $db_instance_id" \
            rds delete-db-instance --db-instance-identifier "$db_instance_id" \
            --skip-final-snapshot --delete-automated-backups || true
    done
    for db_instance_id in $db_instance_ids; do
        best_effort_aws "Wait for RDS instance $db_instance_id to delete" \
            rds wait db-instance-deleted --db-instance-identifier "$db_instance_id" || true
    done

    safe_query db_subnet_group_names "Find RDS subnet groups in $vpc_id" \
        rds describe-db-subnet-groups \
        --query "DBSubnetGroups[?VpcId=='$vpc_id'].DBSubnetGroupName" \
        --output text || true
    for db_subnet_group_name in $db_subnet_group_names; do
        best_effort_aws "Delete RDS subnet group $db_subnet_group_name" \
            rds delete-db-subnet-group --db-subnet-group-name "$db_subnet_group_name" || true
    done
}

delete_nat_gateways_and_eips() {
    local vpc_id="$1"
    local nat_gateway_ids=""
    local allocation_ids=""
    local tagged_allocation_ids=""
    local nat_id
    local allocation_id
    local -A released_allocations=()

    safe_query nat_gateway_ids "Find NAT gateways in $vpc_id" \
        ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$vpc_id" \
        --query 'NatGateways[?State!=`deleted`].NatGatewayId' \
        --output text || true

    safe_query allocation_ids "Find NAT gateway Elastic IP allocations" \
        ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$vpc_id" \
        --query 'NatGateways[].NatGatewayAddresses[].AllocationId' \
        --output text || true
    safe_query tagged_allocation_ids "Find tagged NAT gateway Elastic IP allocations" \
        ec2 describe-addresses \
        --filters "Name=tag:Name,Values=NAT_GW_EIP" \
            "Name=tag:AutoInfraVpcId,Values=$vpc_id" \
        --query 'Addresses[].AllocationId' \
        --output text || true

    for nat_id in $nat_gateway_ids; do
        best_effort_aws "Delete NAT gateway $nat_id" \
            ec2 delete-nat-gateway --nat-gateway-id "$nat_id" || true
    done
    for nat_id in $nat_gateway_ids; do
        best_effort_aws "Wait for NAT gateway $nat_id to delete" \
            ec2 wait nat-gateway-deleted --nat-gateway-ids "$nat_id" || true
    done
    for allocation_id in $allocation_ids $tagged_allocation_ids; do
        if [[ -n "${released_allocations[$allocation_id]:-}" ]]; then
            continue
        fi
        released_allocations["$allocation_id"]=1
        best_effort_aws "Release Elastic IP $allocation_id" \
            ec2 release-address --allocation-id "$allocation_id" || true
    done
}

clear_security_group_rules() {
    local vpc_id="$1"
    local security_group_ids=""
    local security_group_id
    local ingress_permissions=""
    local egress_permissions=""

    safe_query security_group_ids "Find security groups in $vpc_id" \
        ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text || true

    for security_group_id in $security_group_ids; do
        safe_query ingress_permissions "Read ingress rules for $security_group_id" \
            ec2 describe-security-groups \
            --group-ids "$security_group_id" \
            --query 'SecurityGroups[0].IpPermissions' \
            --output json || true
        if [[ -n "$ingress_permissions" && "$ingress_permissions" != "[]" ]]; then
            best_effort_aws "Clear ingress rules for $security_group_id" \
                ec2 revoke-security-group-ingress \
                --group-id "$security_group_id" \
                --ip-permissions "$ingress_permissions" || true
        fi

        safe_query egress_permissions "Read egress rules for $security_group_id" \
            ec2 describe-security-groups \
            --group-ids "$security_group_id" \
            --query 'SecurityGroups[0].IpPermissionsEgress' \
            --output json || true
        if [[ -n "$egress_permissions" && "$egress_permissions" != "[]" ]]; then
            best_effort_aws "Clear egress rules for $security_group_id" \
                ec2 revoke-security-group-egress \
                --group-id "$security_group_id" \
                --ip-permissions "$egress_permissions" || true
        fi
    done
}

delete_network_resources() {
    local vpc_id="$1"
    local internet_gateway_ids=""
    local association_ids=""
    local subnet_ids=""
    local route_table_ids=""
    local security_group_ids=""
    local resource_id

    safe_query association_ids "Find route table associations in $vpc_id" \
        ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'RouteTables[].Associations[?Main!=`true`].RouteTableAssociationId' \
        --output text || true
    for resource_id in $association_ids; do
        best_effort_aws "Disassociate route table $resource_id" \
            ec2 disassociate-route-table --association-id "$resource_id" || true
    done

    safe_query internet_gateway_ids "Find internet gateways in $vpc_id" \
        ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$vpc_id" \
        --query 'InternetGateways[].InternetGatewayId' \
        --output text || true
    for resource_id in $internet_gateway_ids; do
        best_effort_aws "Detach internet gateway $resource_id" \
            ec2 detach-internet-gateway \
            --internet-gateway-id "$resource_id" \
            --vpc-id "$vpc_id" || true
        best_effort_aws "Delete internet gateway $resource_id" \
            ec2 delete-internet-gateway --internet-gateway-id "$resource_id" || true
    done

    safe_query subnet_ids "Find subnets in $vpc_id" \
        ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'Subnets[].SubnetId' \
        --output text || true
    for resource_id in $subnet_ids; do
        best_effort_aws "Delete subnet $resource_id" \
            ec2 delete-subnet --subnet-id "$resource_id" || true
    done

    safe_query route_table_ids "Find non-main route tables in $vpc_id" \
        ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'RouteTables[?length(Associations[?Main==`true`]) == `0`].RouteTableId' \
        --output text || true
    for resource_id in $route_table_ids; do
        best_effort_aws "Delete route table $resource_id" \
            ec2 delete-route-table --route-table-id "$resource_id" || true
    done

    safe_query security_group_ids "Find non-default security groups in $vpc_id" \
        ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text || true
    for resource_id in $security_group_ids; do
        best_effort_aws "Delete security group $resource_id" \
            ec2 delete-security-group --group-id "$resource_id" || true
    done
}

count_remaining_vpc_dependencies() {
    local vpc_id="$1"
    local result_variable="$2"
    local subnets=""
    local security_groups=""
    local route_tables=""
    local nat_gateways=""
    local instances=""
    local total_remaining=0

    safe_query subnets "Check remaining subnets" \
        ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'length(Subnets)' --output text || true
    safe_query security_groups "Check remaining security groups" \
        ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'length(SecurityGroups[?GroupName!=`default`])' --output text || true
    safe_query route_tables "Check remaining route tables" \
        ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'length(RouteTables[?length(Associations[?Main==`true`]) == `0`])' \
        --output text || true
    safe_query nat_gateways "Check remaining NAT gateways" \
        ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" \
        --query 'length(NatGateways[?State!=`deleted`])' --output text || true
    safe_query instances "Check remaining EC2 instances" \
        ec2 describe-instances --filters "Name=vpc-id,Values=$vpc_id" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
        --query 'length(Reservations[].Instances[])' --output text || true

    for remaining_value in "$subnets" "$security_groups" "$route_tables" "$nat_gateways" "$instances"; do
        if [[ "$remaining_value" =~ ^[0-9]+$ ]]; then
            total_remaining=$((total_remaining + remaining_value))
        fi
    done
    local -n result_reference="$result_variable"
    result_reference="$total_remaining"
}

cleanup_vpc() {
    local vpc_id="$1"
    local remaining=0

    print_info "Cleaning VPC: $vpc_id"
    delete_route53_alias_record_for_vpc "$vpc_id" || true
    delete_named_load_balancers "$vpc_id"
    terminate_vpc_instances "$vpc_id"
    delete_rds_resources "$vpc_id"
    delete_nat_gateways_and_eips "$vpc_id"
    clear_security_group_rules "$vpc_id"
    delete_network_resources "$vpc_id"

    print_info "Running a second dependency cleanup pass."
    clear_security_group_rules "$vpc_id"
    delete_network_resources "$vpc_id"
    count_remaining_vpc_dependencies "$vpc_id" remaining

    if (( remaining > 0 )); then
        record_delete_failure "$remaining dependencies remain in $vpc_id"
        return 1
    fi

    if best_effort_aws "Delete VPC $vpc_id" \
        ec2 delete-vpc --vpc-id "$vpc_id"; then
        print_success "Deleted VPC: $vpc_id"
        return 0
    fi
    return 1
}

delete_infrastructure() {
    local skip_confirmation="${1:-false}"
    local show_progress="${2:-true}"
    local vpc_ids=""
    local vpc_id

    DELETE_FAILURES=()
    if [[ "$show_progress" == "true" ]]; then
        init_progress 3 "Delete infrastructure"
    fi
    set_stage "Infrastructure deletion"

    if ! find_vpc_ids vpc_ids; then
        if [[ "$show_progress" == "true" ]]; then
            advance_progress FAILED "VPC discovery failed"
        fi
        return 1
    fi
    if [[ "$show_progress" == "true" ]]; then
        advance_progress RUNNING "VPC discovery completed"
    fi
    if [[ -z "$vpc_ids" ]]; then
        print_info "Nothing to delete."
        if [[ "$show_progress" == "true" ]]; then
            advance_progress SKIPPED "No infrastructure found"
            advance_progress DONE "Infrastructure deletion completed"
        fi
        return 0
    fi

    printf 'Target VPC IDs: %s\n' "$vpc_ids"
    if [[ "$skip_confirmation" != "true" ]]; then
        if ! confirm "Delete all resources in the listed VPCs?"; then
            print_info "Deletion cancelled."
            if [[ "$show_progress" == "true" ]]; then
                render_progress "$PROGRESS_COMPLETED" "$PROGRESS_TOTAL" \
                    SKIPPED "Deletion cancelled"
            fi
            return 0
        fi
    fi

    for vpc_id in $vpc_ids; do
        cleanup_vpc "$vpc_id" || true
    done

    if (( ${#DELETE_FAILURES[@]} > 0 )); then
        print_error "Cleanup completed with ${#DELETE_FAILURES[@]} failure(s):"
        for vpc_id in "${DELETE_FAILURES[@]}"; do
            printf '  - %s\n' "$vpc_id" >&2
        done
        if [[ "$show_progress" == "true" ]]; then
            advance_progress FAILED "Infrastructure deletion failed"
        fi
        return 1
    fi

    if [[ "$show_progress" == "true" ]]; then
        advance_progress RUNNING "Resource cleanup completed"
        advance_progress DONE "Infrastructure deletion completed"
    fi
    print_success "Infrastructure deletion completed."
}

create_vpc_and_network() {
    local vpc_id=""
    local internet_gateway_id=""
    local public_route_table_id=""
    local private_route_table_id=""
    local eip_allocation_id=""
    local nat_gateway_id=""

    local nginx_2a_subnet_id=""
    local nginx_2c_subnet_id=""
    local bastion_subnet_id=""
    local tomcat_2a_subnet_id=""
    local tomcat_2c_subnet_id=""
    local db_2a_subnet_id=""
    local db_2c_subnet_id=""

    set_stage "VPC and network creation"

    aws_query vpc_id "Create VPC" \
        ec2 create-vpc \
        --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=AutoInfraDomain,Value=$DOMAIN_NAME}]" \
        --query 'Vpc.VpcId' --output text || return 1
    CURRENT_VPC_ID="$vpc_id"
    print_success "Created VPC: $CURRENT_VPC_ID"

    aws_mutate "Enable VPC DNS support" \
        ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-support '{"Value":true}' || return 1
    aws_mutate "Enable VPC DNS hostnames" \
        ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-hostnames '{"Value":true}' || return 1

    aws_query internet_gateway_id "Create internet gateway" \
        ec2 create-internet-gateway \
        --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=KWU-PRD-VPC-IGW}]' \
        --query 'InternetGateway.InternetGatewayId' --output text || return 1
    aws_mutate "Attach internet gateway" \
        ec2 attach-internet-gateway \
        --vpc-id "$vpc_id" \
        --internet-gateway-id "$internet_gateway_id" || return 1

    aws_query nginx_2a_subnet_id "Create Nginx 2A public subnet" \
        ec2 create-subnet --vpc-id "$vpc_id" --cidr-block '10.250.1.0/24' \
        --availability-zone 'ap-northeast-2a' \
        --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=KWU-PRD-VPC-NGINX-PUB-2A}]' \
        --query 'Subnet.SubnetId' --output text || return 1
    aws_query nginx_2c_subnet_id "Create Nginx 2C public subnet" \
        ec2 create-subnet --vpc-id "$vpc_id" --cidr-block '10.250.11.0/24' \
        --availability-zone 'ap-northeast-2c' \
        --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=KWU-PRD-VPC-NGINX-PUB-2C}]' \
        --query 'Subnet.SubnetId' --output text || return 1
    aws_query bastion_subnet_id "Create bastion public subnet" \
        ec2 create-subnet --vpc-id "$vpc_id" --cidr-block '10.250.4.0/24' \
        --availability-zone 'ap-northeast-2a' \
        --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=KWU-PRD-VPC-BASTION-PUB-2A}]' \
        --query 'Subnet.SubnetId' --output text || return 1
    aws_query tomcat_2a_subnet_id "Create Tomcat 2A private subnet" \
        ec2 create-subnet --vpc-id "$vpc_id" --cidr-block '10.250.2.0/24' \
        --availability-zone 'ap-northeast-2a' \
        --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=KWU-PRD-VPC-TOMCAT-PRI-2A}]' \
        --query 'Subnet.SubnetId' --output text || return 1
    aws_query tomcat_2c_subnet_id "Create Tomcat 2C private subnet" \
        ec2 create-subnet --vpc-id "$vpc_id" --cidr-block '10.250.12.0/24' \
        --availability-zone 'ap-northeast-2c' \
        --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=KWU-PRD-VPC-TOMCAT-PRI-2C}]' \
        --query 'Subnet.SubnetId' --output text || return 1
    aws_query db_2a_subnet_id "Create database 2A private subnet" \
        ec2 create-subnet --vpc-id "$vpc_id" --cidr-block '10.250.3.0/24' \
        --availability-zone 'ap-northeast-2a' \
        --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=KWU-PRD-VPC-DB-PRI-2A}]' \
        --query 'Subnet.SubnetId' --output text || return 1
    aws_query db_2c_subnet_id "Create database 2C private subnet" \
        ec2 create-subnet --vpc-id "$vpc_id" --cidr-block '10.250.13.0/24' \
        --availability-zone 'ap-northeast-2c' \
        --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=KWU-PRD-VPC-DB-PRI-2C}]' \
        --query 'Subnet.SubnetId' --output text || return 1

    aws_query public_route_table_id "Create public route table" \
        ec2 create-route-table --vpc-id "$vpc_id" \
        --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=KWU-PRD-VPC-RT-PUB}]' \
        --query 'RouteTable.RouteTableId' --output text || return 1
    aws_mutate "Create public default route" \
        ec2 create-route --route-table-id "$public_route_table_id" \
        --destination-cidr-block "$ANYWHERE" --gateway-id "$internet_gateway_id" || return 1
    aws_mutate "Associate Nginx 2A public route" \
        ec2 associate-route-table --subnet-id "$nginx_2a_subnet_id" \
        --route-table-id "$public_route_table_id" || return 1
    aws_mutate "Associate Nginx 2C public route" \
        ec2 associate-route-table --subnet-id "$nginx_2c_subnet_id" \
        --route-table-id "$public_route_table_id" || return 1
    aws_mutate "Associate bastion public route" \
        ec2 associate-route-table --subnet-id "$bastion_subnet_id" \
        --route-table-id "$public_route_table_id" || return 1

    aws_query private_route_table_id "Create private route table" \
        ec2 create-route-table --vpc-id "$vpc_id" \
        --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=KWU-PRD-VPC-RT-PRI}]' \
        --query 'RouteTable.RouteTableId' --output text || return 1

    aws_query eip_allocation_id "Allocate NAT gateway Elastic IP" \
        ec2 allocate-address --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=NAT_GW_EIP},{Key=AutoInfraVpcId,Value=$vpc_id}]" \
        --query 'AllocationId' --output text || return 1
    aws_query nat_gateway_id "Create NAT gateway" \
        ec2 create-nat-gateway \
        --subnet-id "$nginx_2a_subnet_id" \
        --allocation-id "$eip_allocation_id" \
        --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=KWU-PRD-VPC-NGW-2A}]' \
        --query 'NatGateway.NatGatewayId' --output text || return 1
    aws_mutate "Wait for NAT gateway availability" \
        ec2 wait nat-gateway-available --nat-gateway-ids "$nat_gateway_id" || return 1

    aws_mutate "Create private default route" \
        ec2 create-route --route-table-id "$private_route_table_id" \
        --destination-cidr-block "$ANYWHERE" --nat-gateway-id "$nat_gateway_id" || return 1
    aws_mutate "Associate Tomcat 2A private route" \
        ec2 associate-route-table --subnet-id "$tomcat_2a_subnet_id" \
        --route-table-id "$private_route_table_id" || return 1
    aws_mutate "Associate Tomcat 2C private route" \
        ec2 associate-route-table --subnet-id "$tomcat_2c_subnet_id" \
        --route-table-id "$private_route_table_id" || return 1
    aws_mutate "Associate database 2A private route" \
        ec2 associate-route-table --subnet-id "$db_2a_subnet_id" \
        --route-table-id "$private_route_table_id" || return 1
    aws_mutate "Associate database 2C private route" \
        ec2 associate-route-table --subnet-id "$db_2c_subnet_id" \
        --route-table-id "$private_route_table_id" || return 1

    NGINX_2A_SUBNET_ID="$nginx_2a_subnet_id"
    NGINX_2C_SUBNET_ID="$nginx_2c_subnet_id"
    BASTION_SUBNET_ID="$bastion_subnet_id"
    TOMCAT_2A_SUBNET_ID="$tomcat_2a_subnet_id"
    TOMCAT_2C_SUBNET_ID="$tomcat_2c_subnet_id"
    DB_2A_SUBNET_ID="$db_2a_subnet_id"
    DB_2C_SUBNET_ID="$db_2c_subnet_id"
}

create_security_group() {
    local result_variable="$1"
    local group_name="$2"
    local description="$3"
    local group_id=""

    aws_query group_id "Create security group $group_name" \
        ec2 create-security-group \
        --group-name "$group_name" \
        --description "$description" \
        --vpc-id "$CURRENT_VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$group_name}]" \
        --query 'GroupId' --output text || return 1
    printf -v "$result_variable" '%s' "$group_id"
}

authorize_ingress() {
    local group_id="$1"
    local protocol="$2"
    local port="$3"
    local source="$4"
    local permissions

    if [[ "$protocol" == "icmp" ]]; then
        permissions="[{\"IpProtocol\":\"icmp\",\"FromPort\":-1,\"ToPort\":-1,\"IpRanges\":[{\"CidrIp\":\"$source\"}]}]"
        aws_mutate "Authorize ICMP ingress for $group_id" \
            ec2 authorize-security-group-ingress \
            --group-id "$group_id" \
            --ip-permissions "$permissions"
    elif [[ "$source" == sg-* ]]; then
        aws_mutate "Authorize port $port ingress for $group_id" \
            ec2 authorize-security-group-ingress \
            --group-id "$group_id" \
            --protocol "$protocol" \
            --port "$port" \
            --source-group "$source"
    else
        aws_mutate "Authorize port $port ingress for $group_id" \
            ec2 authorize-security-group-ingress \
            --group-id "$group_id" \
            --protocol "$protocol" \
            --port "$port" \
            --cidr "$source"
    fi
}

create_security_groups() {
    local security_group_id

    set_stage "Security group creation"

    create_security_group BASTION_SG_ID "KWU-PRD-VPC-BASTION-PUB-SG-2A" "Bastion SSH and ICMP" || return 1
    create_security_group NGINX_2A_SG_ID "KWU-PRD-VPC-NGINX-PUB-SG-2A" "Nginx public access" || return 1
    create_security_group NGINX_2C_SG_ID "KWU-PRD-VPC-NGINX-PUB-SG-2C" "Nginx public access" || return 1
    create_security_group TOMCAT_2A_SG_ID "KWU-PRD-VPC-TOMCAT-PRI-SG-2A" "Tomcat private access" || return 1
    create_security_group TOMCAT_2C_SG_ID "KWU-PRD-VPC-TOMCAT-PRI-SG-2C" "Tomcat private access" || return 1
    create_security_group ALB_SG_ID "KWU-PRD-VPC-ALB-SG" "Application load balancer" || return 1
    create_security_group DB_SG_ID "KWU-PRD-VPC-DB-PRI-SG-2A" "Database access" || return 1

    authorize_ingress "$BASTION_SG_ID" tcp 22 "$ADMIN_CIDR" || return 1
    authorize_ingress "$BASTION_SG_ID" icmp -1 "$ANYWHERE" || return 1

    for security_group_id in "$NGINX_2A_SG_ID" "$NGINX_2C_SG_ID"; do
        authorize_ingress "$security_group_id" tcp 22 "$BASTION_SG_ID" || return 1
        authorize_ingress "$security_group_id" tcp 80 "$ALB_SG_ID" || return 1
    done

    for security_group_id in "$TOMCAT_2A_SG_ID" "$TOMCAT_2C_SG_ID"; do
        authorize_ingress "$security_group_id" tcp 22 "$BASTION_SG_ID" || return 1
        authorize_ingress "$security_group_id" tcp 8080 "$NGINX_2A_SG_ID" || return 1
        authorize_ingress "$security_group_id" tcp 8080 "$NGINX_2C_SG_ID" || return 1
    done

    authorize_ingress "$ALB_SG_ID" tcp 80 "$ANYWHERE" || return 1
    authorize_ingress "$DB_SG_ID" tcp 3306 "$TOMCAT_2A_SG_ID" || return 1
    authorize_ingress "$DB_SG_ID" tcp 3306 "$TOMCAT_2C_SG_ID" || return 1
}

build_run_instances_args() {
    local result_array_name="$1"
    local subnet_id="$2"
    local associate_public_ip="$3"
    local private_ip="$4"
    local security_group_id="$5"
    local name_tag="$6"
    local user_data="${7:-}"
    local network_interface
    local -n result_array="$result_array_name"

    network_interface="DeviceIndex=0,SubnetId=$subnet_id,Groups=[$security_group_id],AssociatePublicIpAddress=$associate_public_ip,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$private_ip}]"
    result_array=(
        ec2 run-instances
        --image-id "$AMI_ID"
        --instance-type "$INSTANCE_TYPE"
        --count "$INSTANCE_COUNT"
        --key-name "$KEY_NAME"
        --network-interfaces "$network_interface"
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name_tag}]"
    )
    if [[ -n "$user_data" ]]; then
        result_array+=(--user-data "$user_data")
    fi
    result_array+=(
        --query 'Instances[0].InstanceId'
        --output text
    )
}

validate_ec2_launch_cli_model() {
    local -a launch_args=()
    local -a validation_args=()
    local index

    build_run_instances_args launch_args \
        "subnet-00000000000000000" \
        false \
        "10.250.0.10" \
        "sg-00000000000000000" \
        "AUTO-INFRA-CLI-MODEL" \
        ""

    for (( index = 0; index < ${#launch_args[@]}; index += 1 )); do
        case "${launch_args[index]}" in
            --query|--output)
                index=$((index + 1))
                ;;
            *)
                validation_args+=("${launch_args[index]}")
                ;;
        esac
    done

    aws_mutate "Validate EC2 launch CLI model" \
        "${validation_args[@]}" \
        --generate-cli-skeleton output
}

launch_instance() {
    local result_variable="$1"
    local subnet_id="$2"
    local associate_public_ip="$3"
    local private_ip="$4"
    local security_group_id="$5"
    local name_tag="$6"
    local user_data="${7:-}"
    local instance_id=""
    local -a command=()

    build_run_instances_args command \
        "$subnet_id" \
        "$associate_public_ip" \
        "$private_ip" \
        "$security_group_id" \
        "$name_tag" \
        "$user_data"
    aws_query instance_id "Launch EC2 instance $name_tag" "${command[@]}" || return 1
    printf -v "$result_variable" '%s' "$instance_id"
}

launch_instances() {
    local nginx_2a_user_data
    local nginx_2c_user_data
    local tomcat_2a_user_data
    local tomcat_2c_user_data

    set_stage "EC2 instance creation"
    nginx_2a_user_data="$(build_nginx_user_data "2A")" || return 1
    nginx_2c_user_data="$(build_nginx_user_data "2C")" || return 1
    tomcat_2a_user_data="$(build_tomcat_user_data "2A" "$DB_ENDPOINT")" || return 1
    tomcat_2c_user_data="$(build_tomcat_user_data "2C" "$DB_ENDPOINT")" || return 1

    launch_instance BASTION_INSTANCE_ID "$BASTION_SUBNET_ID" true "10.250.4.240" \
        "$BASTION_SG_ID" "KWU-PRD-VPC-BASTION-PUB-2A" || return 1
    launch_instance NGINX_2A_INSTANCE_ID "$NGINX_2A_SUBNET_ID" true "10.250.1.240" \
        "$NGINX_2A_SG_ID" "KWU-PRD-VPC-NGINX-PUB-2A" "$nginx_2a_user_data" || return 1
    launch_instance NGINX_2C_INSTANCE_ID "$NGINX_2C_SUBNET_ID" true "10.250.11.240" \
        "$NGINX_2C_SG_ID" "KWU-PRD-VPC-NGINX-PUB-2C" "$nginx_2c_user_data" || return 1
    launch_instance TOMCAT_2A_INSTANCE_ID "$TOMCAT_2A_SUBNET_ID" false "10.250.2.240" \
        "$TOMCAT_2A_SG_ID" "KWU-PRD-VPC-TOMCAT-PRI-2A" "$tomcat_2a_user_data" || return 1
    launch_instance TOMCAT_2C_INSTANCE_ID "$TOMCAT_2C_SUBNET_ID" false "10.250.12.240" \
        "$TOMCAT_2C_SG_ID" "KWU-PRD-VPC-TOMCAT-PRI-2C" "$tomcat_2c_user_data" || return 1

    ALL_INSTANCE_IDS="$BASTION_INSTANCE_ID $NGINX_2A_INSTANCE_ID $NGINX_2C_INSTANCE_ID $TOMCAT_2A_INSTANCE_ID $TOMCAT_2C_INSTANCE_ID"
    aws_mutate "Wait for EC2 instances to run" \
        ec2 wait instance-running --instance-ids $ALL_INSTANCE_IDS || return 1
    aws_mutate "Wait for EC2 status checks" \
        ec2 wait instance-status-ok --instance-ids $ALL_INSTANCE_IDS || return 1
}

create_database() {
    local db_endpoint=""

    set_stage "RDS database creation"
    aws_mutate "Create RDS DB subnet group" \
        rds create-db-subnet-group \
        --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
        --db-subnet-group-description "Private subnets for $DB_INSTANCE_IDENTIFIER" \
        --subnet-ids "$DB_2A_SUBNET_ID" "$DB_2C_SUBNET_ID" \
        --tags "Key=Name,Value=$DB_SUBNET_GROUP_NAME" "Key=AutoInfraVpcId,Value=$CURRENT_VPC_ID" || return 1
    aws_mutate "Create private RDS MySQL instance" \
        rds create-db-instance \
        --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
        --engine mysql \
        --db-instance-class db.t3.micro \
        --allocated-storage 20 \
        --db-name "$DB_NAME" \
        --master-username "$DB_MASTER_USERNAME" \
        --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
        --vpc-security-group-ids "$DB_SG_ID" \
        --no-publicly-accessible \
        --backup-retention-period 0 \
        --manage-master-user-password \
        --tags "Key=Name,Value=$DB_INSTANCE_IDENTIFIER" "Key=AutoInfraVpcId,Value=$CURRENT_VPC_ID" || return 1
    aws_mutate "Wait for RDS MySQL instance" \
        rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" || return 1
    aws_query db_endpoint "Read RDS endpoint" \
        rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
        --query 'DBInstances[0].Endpoint.Address' --output text || return 1
    if [[ -z "$db_endpoint" || "$db_endpoint" == "None" ]]; then
        LAST_ERROR="RDS endpoint is unavailable."
        return 1
    fi
    DB_ENDPOINT="$db_endpoint"
    print_success "Created private RDS MySQL instance: $DB_INSTANCE_IDENTIFIER"
}

create_application_load_balancer() {
    aws_query ALB_ARN "Create application load balancer" \
        elbv2 create-load-balancer --name "$APPLICATION_LOAD_BALANCER_NAME" \
        --type application --scheme internet-facing \
        --subnets "$NGINX_2A_SUBNET_ID" "$NGINX_2C_SUBNET_ID" \
        --security-groups "$ALB_SG_ID" \
        --tags "Key=Name,Value=$APPLICATION_LOAD_BALANCER_NAME" "Key=AutoInfraVpcId,Value=$CURRENT_VPC_ID" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text || return 1
    aws_query TARGET_GROUP_ARN "Create ALB target group" \
        elbv2 create-target-group --name "$TARGET_GROUP_NAME" --protocol HTTP --port 80 \
        --target-type instance --vpc-id "$CURRENT_VPC_ID" --health-check-path / \
        --query 'TargetGroups[0].TargetGroupArn' --output text || return 1
    aws_mutate "Register Nginx instances with ALB target group" \
        elbv2 register-targets --target-group-arn "$TARGET_GROUP_ARN" \
        --targets "Id=$NGINX_2A_INSTANCE_ID,Port=80" "Id=$NGINX_2C_INSTANCE_ID,Port=80" || return 1
    aws_mutate "Create ALB HTTP listener" \
        elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
        --default-actions "Type=forward,TargetGroupArn=$TARGET_GROUP_ARN" || return 1
    aws_mutate "Wait for ALB targets to become healthy" \
        elbv2 wait target-in-service --target-group-arn "$TARGET_GROUP_ARN" \
        --targets "Id=$NGINX_2A_INSTANCE_ID,Port=80" "Id=$NGINX_2C_INSTANCE_ID,Port=80" || return 1
    aws_query ALB_DNS_NAME "Read ALB DNS name" \
        elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
        --query 'LoadBalancers[0].DNSName' --output text || return 1
    aws_query ALB_HOSTED_ZONE_ID "Read ALB hosted zone ID" \
        elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
        --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text || return 1
    if [[ -z "$ALB_DNS_NAME" || "$ALB_DNS_NAME" == "None" || -z "$ALB_HOSTED_ZONE_ID" || "$ALB_HOSTED_ZONE_ID" == "None" ]]; then
        LAST_ERROR="Application load balancer DNS details are unavailable."
        return 1
    fi
    print_success "Created application load balancer: $APPLICATION_LOAD_BALANCER_NAME"
}

upsert_route53_alias_record() {
    local record_name
    local change_batch
    local change_id=""

    record_name="$(fqdn_with_dot "$DOMAIN_NAME")" || return 1
    ALB_ALIAS_DNS_NAME="dualstack.${ALB_DNS_NAME%.}."
    change_batch="$(build_route53_alias_change_batch UPSERT \
        "$record_name" "$ALB_ALIAS_DNS_NAME" "$ALB_HOSTED_ZONE_ID")"

    aws_query change_id "Upsert Route 53 alias record" \
        route53 change-resource-record-sets \
        --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" \
        --change-batch "$change_batch" \
        --query 'ChangeInfo.Id' \
        --output text || return 1
    if [[ -n "$change_id" && "$change_id" != "None" ]]; then
        aws_mutate "Wait for Route 53 alias record" \
            route53 wait resource-record-sets-changed --id "$change_id" || return 1
    fi
    print_success "Route 53 alias record is ready: $record_name"
}

create_load_balancer_and_dns() {
    set_stage "Application load balancer and DNS creation"

    create_application_load_balancer || return 1
    upsert_route53_alias_record || return 1
}

get_instance_public_ip() {
    local result_variable="$1"
    local instance_id="$2"
    local public_ip=""

    aws_query public_ip "Read public IP for $instance_id" \
        ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text || return 1
    if [[ -z "$public_ip" || "$public_ip" == "None" ]]; then
        LAST_ERROR="No public IP was assigned to $instance_id"
        print_error "$LAST_ERROR"
        return 1
    fi
    printf -v "$result_variable" '%s' "$public_ip"
}

verify_nginx_url() {
    local target="$1"
    local expected_identifier="$2"
    local attempt=1
    local response=""
    local url=""

    if [[ "$target" == http://* || "$target" == https://* ]]; then
        url="$target"
    else
        url="http://${target%/}/"
    fi

    while (( attempt <= HTTP_VERIFY_ATTEMPTS )); do
        if (( CREATE_INTERRUPTED == 1 )); then
            LAST_ERROR="Creation interrupted by the user."
            return 130
        fi
        if response="$(curl --fail --silent --show-error \
            --connect-timeout 5 --max-time 10 "$url" 2>>"${LOG_FILE:-/dev/null}")"; then
            if [[ "$response" == *"$expected_identifier"* ]]; then
                print_success "Verified Nginx page at $url"
                return 0
            fi
        fi
        log_line "INFO" "Waiting for Nginx at $url (attempt $attempt)"
        sleep "$HTTP_VERIFY_DELAY_SECONDS"
        attempt=$((attempt + 1))
    done

    LAST_ERROR="Nginx verification timed out for $url"
    print_error "$LAST_ERROR"
    return 1
}

verify_deployment() {
    set_stage "Deployment verification"

    get_instance_public_ip BASTION_PUBLIC_IP "$BASTION_INSTANCE_ID" || return 1

    verify_nginx_url "$ALB_DNS_NAME" "KWU-PRD-VPC-NGINX-PUB" || return 1
    verify_nginx_url "http://$ALB_DNS_NAME/app/" "Tomcat WAS is working" || return 1

    if ! verify_nginx_url "$DOMAIN_NAME" "KWU-PRD-VPC-NGINX-PUB"; then
        print_warning "Domain connectivity was not verified yet. DNS propagation may still be in progress."
    fi
}

show_deployment_summary() {
    printf '\n'
    printf '+----------------------------------------------------------+\n'
    printf '|                 Deployment Summary                       |\n'
    printf '+----------------------------------------------------------+\n'
    printf '  %-20s %s\n' "VPC ID" "$CURRENT_VPC_ID"
    printf '  %-20s %s\n' "Domain" "$DOMAIN_NAME"
    printf '  %-20s %s\n' "Hosted Zone" "$ROUTE53_HOSTED_ZONE_ID"
    printf '  %-20s %s\n' "Bastion public IP" "$BASTION_PUBLIC_IP"
    printf '  %-20s http://%s\n' "ALB" "$ALB_DNS_NAME"
    printf '  %-20s http://%s\n' "DNS Alias" "$DOMAIN_NAME"
    printf '  %-20s http://%s/app/\n' "Tomcat application" "$DOMAIN_NAME"
    printf '  %-20s %s\n' "RDS endpoint" "$DB_ENDPOINT"
    printf '  %-20s %s\n' "RDS credentials" "Managed in AWS Secrets Manager"
    printf '+----------------------------------------------------------+\n'
}

handle_creation_failure() {
    local choice

    CREATE_ACTIVE=0
    printf '\n'
    print_error "Infrastructure creation failed during: $CURRENT_STAGE"
    if [[ -n "$LAST_ERROR" ]]; then
        print_error "$LAST_ERROR"
    fi
    if [[ -n "$CURRENT_VPC_ID" ]]; then
        printf 'Current VPC ID: %s\n' "$CURRENT_VPC_ID"
    fi

    while true; do
        printf '1) Roll back created resources\n'
        printf '2) Keep resources for investigation\n'
        printf 'Select an option [1-2]: '
        if ! IFS= read -r choice; then
            choice="2"
        fi
        case "$choice" in
            1)
                print_warning "Starting rollback."
                delete_infrastructure "true" "false" || true
                return 0
                ;;
            2)
                print_warning "Resources were kept for investigation."
                [[ -n "$LOG_FILE" ]] && printf 'Log file: %s\n' "$LOG_FILE"
                return 0
                ;;
            *)
                print_error "Enter 1 or 2."
                ;;
        esac
    done
}

handle_interrupt() {
    CREATE_INTERRUPTED=1
    if (( CREATE_ACTIVE == 1 )); then
        LAST_ERROR="Creation interrupted by the user."
        print_warning "$LAST_ERROR"
    else
        print_warning "Operation interrupted."
    fi
}

create_infrastructure() {
    local existing_vpc_ids=""

    if ! prompt_domain; then
        print_info "Creation cancelled. No AWS resources were changed."
        return 1
    fi

    CREATE_ACTIVE=1
    CREATE_INTERRUPTED=0
    CURRENT_VPC_ID=""
    LAST_ERROR=""
    init_progress 8 "Create infrastructure"

    if ! check_prerequisites; then
        advance_progress FAILED "Prerequisite checks failed"
        handle_creation_failure
        return 1
    fi
    advance_progress RUNNING "Prerequisite checks completed"

    set_stage "Existing infrastructure check"
    if ! find_vpc_ids existing_vpc_ids; then
        advance_progress FAILED "Existing infrastructure check failed"
        handle_creation_failure
        return 1
    fi
    if [[ -n "$existing_vpc_ids" ]]; then
        print_warning "Existing infrastructure will be deleted before recreation."
        printf 'Existing VPC IDs: %s\n' "$existing_vpc_ids"
        if confirm "Continue with destructive replacement?"; then
            :
        elif (( CREATE_INTERRUPTED == 1 )); then
            LAST_ERROR="Creation interrupted by the user."
            handle_creation_failure
            return 1
        else
            CREATE_ACTIVE=0
            print_info "Creation cancelled. Existing resources were not changed."
            return 0
        fi
        if ! delete_infrastructure "true" "false"; then
            LAST_ERROR="Existing infrastructure could not be deleted completely."
            advance_progress FAILED "Existing infrastructure cleanup failed"
            handle_creation_failure
            return 1
        fi
    fi
    advance_progress RUNNING "Existing infrastructure check completed"

    if ! create_vpc_and_network; then
        advance_progress FAILED "VPC and network creation failed"
        handle_creation_failure
        return 1
    fi
    advance_progress RUNNING "VPC and network creation completed"

    if ! create_security_groups; then
        advance_progress FAILED "Security group creation failed"
        handle_creation_failure
        return 1
    fi
    advance_progress RUNNING "Security group creation completed"

    if ! create_database; then
        advance_progress FAILED "RDS database creation failed"
        handle_creation_failure
        return 1
    fi
    advance_progress RUNNING "RDS database creation completed"

    if ! launch_instances; then
        advance_progress FAILED "EC2 instance creation failed"
        handle_creation_failure
        return 1
    fi
    advance_progress RUNNING "EC2 instance creation completed"

    if ! create_load_balancer_and_dns; then
        advance_progress FAILED "Application load balancer and DNS creation failed"
        handle_creation_failure
        return 1
    fi
    advance_progress RUNNING "Application load balancer and DNS creation completed"

    if ! verify_deployment; then
        advance_progress FAILED "Deployment verification failed"
        handle_creation_failure
        return 1
    fi

    CREATE_ACTIVE=0
    set_stage "Creation complete"
    show_deployment_summary
    advance_progress DONE "Infrastructure creation completed"
    print_success "Infrastructure creation completed."
}

draw_main_menu() {
    printf '\n'
    show_logo
    printf '+----------------------------------------------------------+\n'
    printf '|              AWS Infrastructure Automation               |\n'
    printf '+----------------------------------------------------------+\n'
    printf '|  1) Create infrastructure                                |\n'
    printf '|  2) Delete infrastructure                                |\n'
    printf '|  3) Test ALB and application connectivity                |\n'
    printf '|  4) Exit                                                 |\n'
    printf '+----------------------------------------------------------+\n'
}

pause_for_enter() {
    if [[ -t 0 ]]; then
        printf 'Press Enter to continue...'
        IFS= read -r _ || true
    fi
}

test_application_load_balancer_for_vpc() {
    local vpc_id="$1"
    local alb_dns_names=""
    local alb_dns_name
    local failures=0

    if ! aws_query alb_dns_names "Find application load balancers for $vpc_id" \
        elbv2 describe-load-balancers \
        --query "LoadBalancers[?VpcId=='$vpc_id' && Type=='application'].DNSName" \
        --output text; then
        return 1
    fi
    if [[ -z "$alb_dns_names" ]]; then
        print_error "No application load balancer found for $vpc_id."
        return 1
    fi

    for alb_dns_name in $alb_dns_names; do
        verify_nginx_url "$alb_dns_name" "KWU-PRD-VPC-NGINX-PUB" || failures=$((failures + 1))
        verify_nginx_url "http://$alb_dns_name/app/" "Tomcat WAS is working" || failures=$((failures + 1))
    done

    (( failures == 0 ))
}

run_connectivity_tests() {
    local vpc_ids=""
    local vpc_id
    local domain=""
    local failures=0

    init_progress 3 "Test ALB and application connectivity"
    set_stage "ALB and application connectivity test"

    if ! find_vpc_ids vpc_ids; then
        advance_progress FAILED "VPC discovery failed"
        return 1
    fi
    if [[ -z "$vpc_ids" ]]; then
        print_error "No generated infrastructure was found."
        advance_progress FAILED "No infrastructure found"
        return 1
    fi
    advance_progress RUNNING "VPC discovery completed"

    for vpc_id in $vpc_ids; do
        print_info "Testing VPC: $vpc_id"
        test_application_load_balancer_for_vpc "$vpc_id" || failures=$((failures + 1))
    done
    advance_progress RUNNING "ALB and Tomcat proxy checks completed"

    for vpc_id in $vpc_ids; do
        if read_vpc_domain domain "$vpc_id" && [[ -n "$domain" ]]; then
            verify_nginx_url "$domain" "KWU-PRD-VPC-NGINX-PUB" || failures=$((failures + 1))
        else
            print_warning "No domain tag found for $vpc_id. Skipping DNS connectivity check."
        fi
    done

    if (( failures > 0 )); then
        advance_progress FAILED "ALB and application connectivity test failed"
        print_error "ALB and application connectivity test completed with $failures failure(s)."
        return 1
    fi

    advance_progress DONE "ALB and application connectivity test completed"
    print_success "ALB and application connectivity test completed."
}

main_menu() {
    local choice

    while true; do
        draw_main_menu
        printf 'Select an option [1-4]: '
        if ! IFS= read -r choice; then
            choice="4"
        fi

        case "$choice" in
            1)
                create_infrastructure || true
                pause_for_enter
                ;;
            2)
                delete_infrastructure || true
                pause_for_enter
                ;;
            3)
                run_connectivity_tests || true
                pause_for_enter
                ;;
            4)
                print_info "Exiting."
                return 0
                ;;
            *)
                print_error "Invalid selection. Enter 1, 2, 3, or 4."
                ;;
        esac
    done
}

main() {
    init_colors
    if ! init_logging; then
        return 1
    fi
    trap handle_interrupt INT
    print_info "Region: $AWS_REGION"
    print_info "Log file: $LOG_FILE"
    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
