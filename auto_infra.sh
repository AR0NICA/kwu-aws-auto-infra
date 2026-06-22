#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/lib/infrastructure.sh"
source "$ROOT_DIR/modules/identity.sh"
source "$ROOT_DIR/modules/board.sh"
main "$@"
