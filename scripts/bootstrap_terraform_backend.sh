#!/usr/bin/env bash

set -euo pipefail

AWS_REGION="ap-northeast-2"
STATE_BUCKET="kwu-prd-vpc-terraform-state"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v aws >/dev/null 2>&1 || fail "AWS CLI is required."

if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  printf 'Terraform backend bucket already exists: %s\n' "$STATE_BUCKET"
else
  printf 'Creating Terraform backend bucket: %s\n' "$STATE_BUCKET"
  aws s3api create-bucket \
    --bucket "$STATE_BUCKET" \
    --region "$AWS_REGION" \
    --create-bucket-configuration "LocationConstraint=$AWS_REGION" || \
    fail "Unable to create $STATE_BUCKET. The name may be owned by another AWS account or your IAM role lacks S3 permissions."
fi

aws s3api put-bucket-versioning \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket "$STATE_BUCKET" \
  --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

aws s3api put-bucket-ownership-controls \
  --bucket "$STATE_BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

printf 'Terraform backend is ready: s3://%s/kwu-prd-vpc/terraform.tfstate\n' "$STATE_BUCKET"
