#!/usr/bin/env bash
#
# One-time bootstrap: creates the S3 bucket + DynamoDB table used as the
# Terraform remote state backend by all three layers.
#
# Idempotent: safe to re-run; skips resources that already exist.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${TF_STATE_BUCKET:-e2e3t-tfstate-${ACCOUNT_ID}}"
TABLE="${TF_LOCK_TABLE:-e2e3t-tflocks}"

echo "Region:      ${REGION}"
echo "Account:     ${ACCOUNT_ID}"
echo "S3 bucket:   ${BUCKET}"
echo "Lock table:  ${TABLE}"
echo

# ------------- S3 bucket -------------
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "S3 bucket ${BUCKET} already exists — skipping create."
else
  echo "Creating S3 bucket ${BUCKET}..."
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET}" \
      --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
fi

echo "Enabling versioning on ${BUCKET}..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

echo "Enabling default encryption on ${BUCKET}..."
aws s3api put-bucket-encryption \
  --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "Blocking public access on ${BUCKET}..."
aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# ------------- DynamoDB lock table -------------
if aws dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "DynamoDB table ${TABLE} already exists — skipping create."
else
  echo "Creating DynamoDB table ${TABLE}..."
  aws dynamodb create-table \
    --table-name "${TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  echo "Waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists --table-name "${TABLE}" --region "${REGION}"
fi

cat <<EOF

Bootstrap complete.

Set these in each layer's terraform.tfvars (or export as env vars):

  state_bucket = "${BUCKET}"
  state_table  = "${TABLE}"
  region       = "${REGION}"
  account_id   = "${ACCOUNT_ID}"

Next: cd foundation && terraform init && terraform apply
EOF
