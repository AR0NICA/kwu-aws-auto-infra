#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
terraform_bin="${TERRAFORM_BIN:-terraform}"

command -v "$terraform_bin" >/dev/null 2>&1 || {
  printf 'ERROR: Terraform 1.10 or later is required.\n' >&2
  exit 1
}

bash "$script_dir/bootstrap_terraform_backend.sh"
exec "$terraform_bin" "$@"
