#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  cleanup_legacy_route53_alias.sh --hosted-zone-id ZONE_ID --record-name example.com [--apply]

Reads the exact current Route 53 A alias record and, only when it targets an
Elastic Load Balancing hostname, deletes that exact record. Without --apply it
prints the change batch and makes no AWS changes.
USAGE
}

hosted_zone_id=""
record_name=""
apply=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hosted-zone-id)
      hosted_zone_id="${2:-}"
      shift 2
      ;;
    --record-name)
      record_name="${2:-}"
      shift 2
      ;;
    --apply)
      apply=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$hosted_zone_id" || -z "$record_name" ]]; then
  usage >&2
  exit 2
fi

for command in aws jq; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  }
done

record_name="${record_name%.}."
response="$(aws route53 list-resource-record-sets \
  --hosted-zone-id "$hosted_zone_id" \
  --start-record-name "$record_name" \
  --start-record-type A \
  --max-items 1 \
  --output json)"

record_set="$(jq -c --arg name "$record_name" '
  .ResourceRecordSets[0]
  | select(.Name == $name and .Type == "A" and .AliasTarget != null)
' <<<"$response")"

if [[ -z "$record_set" || "$record_set" == "null" ]]; then
  printf 'No A alias record found for %s in hosted zone %s.\n' "$record_name" "$hosted_zone_id" >&2
  exit 1
fi

alias_dns_name="$(jq -r '.AliasTarget.DNSName' <<<"$record_set")"
if [[ "$alias_dns_name" != *.elb.amazonaws.com. ]]; then
  printf 'Refusing to delete %s because it does not target an ELB hostname: %s\n' \
    "$record_name" "$alias_dns_name" >&2
  exit 1
fi

change_batch="$(jq -cn --argjson record "$record_set" '{
  Comment: "Delete legacy ALB alias record using the exact Route 53 record set",
  Changes: [{Action: "DELETE", ResourceRecordSet: $record}]
}')"

printf 'Prepared deletion for %s → %s\n' "$record_name" "$alias_dns_name"
jq . <<<"$change_batch"

if [[ "$apply" != true ]]; then
  printf 'Dry-run only. Re-run with --apply to delete this record.\n'
  exit 0
fi

change_id="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$hosted_zone_id" \
  --change-batch "$change_batch" \
  --query 'ChangeInfo.Id' \
  --output text)"
aws route53 wait resource-record-sets-changed --id "$change_id"
printf 'Deleted legacy Route 53 alias record: %s\n' "$record_name"
