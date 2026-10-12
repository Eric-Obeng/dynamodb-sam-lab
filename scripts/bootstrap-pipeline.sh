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

# On Windows (Git Bash) the SAM CLI installer only provides sam.cmd.
if command -v sam >/dev/null 2>&1; then SAM=sam; else SAM=sam.cmd; fi

# --cicd-provider is required alongside --oidc-provider: when it is omitted,
# SAM CLI resets the OIDC provider to None and fails with
# "Missing required parameter '--oidc-provider'".
#
# SAM CLI also saves deployment_branch into [default] of pipelineconfig.toml
# and, on the next run, lets that saved value OVERRIDE --deployment-branch.
# Without the sed below, the prod role would trust "develop" instead of "main".
PIPELINE_CONFIG=".aws-sam/pipeline/pipelineconfig.toml"

bootstrap_stage() {
  local stage="$1" branch="$2"
  if [[ -f "$PIPELINE_CONFIG" ]]; then
    sed -i "s|^deployment_branch = .*|deployment_branch = \"$branch\"|" "$PIPELINE_CONFIG"
  fi
  "$SAM" pipeline bootstrap \
    --no-interactive \
    --stage "$stage" \
    --region "$REGION" \
    --permissions-provider oidc \
    --cicd-provider github-actions \
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
