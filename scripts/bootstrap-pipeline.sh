#!/usr/bin/env bash
# One-time, run locally with admin AWS credentials.
#
# Runs `sam pipeline bootstrap` once per stage. Each run creates a
# separate CloudFormation stack (aws-sam-cli-managed-<stage>-pipeline-resources)
# containing that stage's own:
#   - artifacts S3 bucket          -> <STAGE>_ARTIFACTS_BUCKET
#   - pipeline execution role      -> <STAGE>_PIPELINE_EXECUTION_ROLE (assumed via GitHub OIDC)
#   - CloudFormation execution role-> <STAGE>_CLOUDFORMATION_EXECUTION_ROLE
#
# Each stage's OIDC trust is pinned to its own branch (dev -> develop,
# prod -> main), so the dev workflow can never assume the prod role.
# Resulting ARNs/bucket names are written to .aws-sam/pipeline/pipelineconfig.toml.
set -euo pipefail

REGION="${REGION:-eu-central-1}"
GITHUB_ORG="${GITHUB_ORG:-Eric-Obeng}"
GITHUB_REPO="${GITHUB_REPO:-dynamodb-sam-lab}"

bootstrap_stage() {
  local stage="$1" branch="$2"
  sam pipeline bootstrap \
    --no-interactive \
    --stage "$stage" \
    --region "$REGION" \
    --permissions-provider oidc \
    --oidc-provider github-actions \
    --oidc-provider-url https://token.actions.githubusercontent.com \
    --oidc-client-id sts.amazonaws.com \
    --github-org "$GITHUB_ORG" \
    --github-repo "$GITHUB_REPO" \
    --deployment-branch "$branch" \
    --no-create-image-repository \
    --no-confirm-changeset
}

bootstrap_stage dev develop
bootstrap_stage prod main

echo
echo "Done. Copy these into GitHub repo variables (Settings > Secrets and variables > Actions > Variables):"
cat .aws-sam/pipeline/pipelineconfig.toml
