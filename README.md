# dynamodb-sam-lab

An Amazon DynamoDB table defined with AWS SAM and deployed to two environments (dev and prod)
by SAM Pipelines and GitHub Actions, in `eu-central-1`.

## Table design

`dynamodb-sam-lab-<env>-tasks` uses **On-Demand** billing (`PAY_PER_REQUEST`) and the
**Standard-Infrequent Access** table class (`STANDARD_INFREQUENT_ACCESS`), not the default
`STANDARD`.

| Attribute   | Type | Role                                      |
|-------------|------|-------------------------------------------|
| `taskId`    | S    | Primary key (partition key)               |
| `status`    | S    | `StatusIndex` partition key               |
| `dueDate`   | S    | `StatusIndex` sort key                    |
| `assignee`  | S    | `AssigneeIndex` partition key             |
| `createdAt` | S    | `AssigneeIndex` sort key                  |
| `title`     | S    | Non-key attribute                         |
| `priority`  | S    | Non-key attribute                         |

| GSI             | Keys                    | Access pattern                          |
|-----------------|-------------------------|-----------------------------------------|
| `StatusIndex`   | `status` / `dueDate`    | Tasks in a given status, by due date    |
| `AssigneeIndex` | `assignee` / `createdAt`| Tasks for a given person, by creation   |

Prod also gets deletion protection, point-in-time recovery, and `DeletionPolicy: Retain`.

## Repo layout

```text
template.yaml                      # SAM template: the Tasks table
samconfig.toml                     # Per-environment deploy config ([dev] / [prod])
scripts/bootstrap-pipeline.sh      # One-time: sam pipeline bootstrap for dev + prod
.github/workflows/
  deploy-dev.yml                   # push to develop -> deploys the dev stack only
  deploy-prod.yml                  # push to main    -> deploys the prod stack only
docs/sample-items.json             # Sample items for console CRUD testing
```

## Pipeline design

| Environment | Branch    | Workflow          | Stack                   | Artifacts bucket            |
|-------------|-----------|-------------------|-------------------------|-----------------------------|
| dev         | `develop` | `deploy-dev.yml`  | `dynamodb-sam-lab-dev`  | bucket from `--stage dev`   |
| prod        | `main`    | `deploy-prod.yml` | `dynamodb-sam-lab-prod` | bucket from `--stage prod`  |

- `sam pipeline bootstrap` runs once per stage. Each stage gets its own artifacts bucket,
  pipeline execution role, and CloudFormation execution role.
- GitHub authenticates through OIDC, so no long-lived AWS keys are stored. Each stage's role
  trusts only its own branch, so the dev workflow can't assume the prod role.
- This repo doesn't use `sam pipeline init`'s single multi-stage workflow. It has two
  hand-written workflows, one per environment, and each one deploys only its own stack.

## Setup

Prerequisites: the AWS CLI, [SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html),
and admin credentials for the target account.

1. **One-time:** bootstrap both pipeline stages:

   ```bash
   ./scripts/bootstrap-pipeline.sh
   ```

2. **One-time:** from `.aws-sam/pipeline/pipelineconfig.toml`, set these GitHub repo
   **variables** (Settings → Secrets and variables → Actions → Variables):

   | Variable                              | Source (stage `dev` / `prod`)       |
   |---------------------------------------|-------------------------------------|
   | `DEV_REGION` / `PROD_REGION`          | `region`                            |
   | `DEV_PIPELINE_EXECUTION_ROLE` / `PROD_…`        | `pipeline_execution_role`           |
   | `DEV_CLOUDFORMATION_EXECUTION_ROLE` / `PROD_…`  | `cloudformation_execution_role`     |
   | `DEV_ARTIFACTS_BUCKET` / `PROD_…`               | `artifacts_bucket`                  |

3. Commit `.aws-sam/pipeline/pipelineconfig.toml`, then create a `develop` branch and push
   it. That deploys dev. Merge `develop` into `main` to deploy prod.

## Verification (console CRUD)

1. Go to DynamoDB → Tables → `dynamodb-sam-lab-dev-tasks`. Check that the capacity mode is
   *On-demand* and the table class is *DynamoDB Standard-IA*.
2. **Create:** Explore items → Create item → JSON view, then paste an item from
   `docs/sample-items.json`.
3. **Read:** Scan the table, or Query `StatusIndex` with `status = TODO`, or Query
   `AssigneeIndex` with `assignee = eric`.
4. **Update:** open an item and change `status` to `DONE`.
5. **Delete:** select an item → Actions → Delete items.
