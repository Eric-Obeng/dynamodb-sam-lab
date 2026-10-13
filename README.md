# dynamodb-sam-lab

An Amazon DynamoDB table defined with AWS SAM and deployed to two environments (dev and prod)
by SAM Pipelines and GitHub Actions, in `eu-central-1`.

## Architecture

```mermaid
flowchart LR
  subgraph GitHub["GitHub: Eric-Obeng/dynamodb-sam-lab"]
    dev_branch["develop branch"] --> dev_wf["deploy-dev.yml<br/>validate → deploy"]
    main_branch["main branch"] --> prod_wf["deploy-prod.yml<br/>validate → deploy"]
  end

  subgraph AWS["AWS account · eu-central-1"]
    subgraph DevStage["sam pipeline bootstrap --stage dev"]
      dev_role["dev pipeline execution role<br/>(OIDC, trusts develop only)"]
      dev_bucket[("dev artifacts bucket")]
      dev_cfn_role["dev CloudFormation execution role<br/>(DynamoDB on dev tables only)"]
    end
    subgraph ProdStage["sam pipeline bootstrap --stage prod"]
      prod_role["prod pipeline execution role<br/>(OIDC, trusts main only)"]
      prod_bucket[("prod artifacts bucket")]
      prod_cfn_role["prod CloudFormation execution role<br/>(DynamoDB on prod tables only)"]
    end
    dev_stack["stack dynamodb-sam-lab-dev<br/>table dynamodb-sam-lab-dev-tasks"]
    prod_stack["stack dynamodb-sam-lab-prod<br/>table dynamodb-sam-lab-prod-tasks"]
  end

  dev_wf -- "assume role (OIDC)" --> dev_role
  dev_role -- "upload template" --> dev_bucket
  dev_role -- "pass role" --> dev_cfn_role --> dev_stack

  prod_wf -- "assume role (OIDC)" --> prod_role
  prod_role -- "upload template" --> prod_bucket
  prod_role -- "pass role" --> prod_cfn_role --> prod_stack
```

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

Both GSIs use `ProjectionType: ALL`, so a query on an index returns the whole item in the
console without a second lookup.

### Per-environment settings

| Setting | dev | prod |
| --- | --- | --- |
| `DeletionPolicy` / `UpdateReplacePolicy` | `Delete` | `Retain` |
| Deletion protection | off | on |
| Point-in-time recovery | off | on |
| Encryption at rest | on (DynamoDB default, AWS-owned key) | on (DynamoDB default, AWS-owned key) |

## Design decisions

| Decision | Why |
| --- | --- |
| `AWS::DynamoDB::Table` instead of `AWS::Serverless::SimpleTable` | `SimpleTable` can't define GSIs, a sort key, or `TableClass`. A plain CloudFormation resource is still valid in a SAM template. |
| `AWS::LanguageExtensions` transform | Lets `DeletionPolicy` / `UpdateReplacePolicy` use `Fn::If`, so one template serves both environments. It has to be listed before the SAM transform. |
| `CAPABILITY_AUTO_EXPAND`, not `CAPABILITY_IAM` | The template creates no IAM resources. `AUTO_EXPAND` is the only capability the transforms need. |
| One self-contained `samconfig.toml` block per environment | With `--config-env`, SAM CLI ignores `[default.*]` sections. Keeping `stack_name` in `global.parameters` means every command (`deploy`, `list stack-outputs`, `delete`) reads it from one place. |
| Bucket and role ARNs come from GitHub repo variables, not `samconfig.toml` | Each environment deploys through its own bootstrap outputs, and no account-specific values are committed. |
| Custom least-privilege CloudFormation execution role per environment | `sam pipeline bootstrap`'s default execution role allows `Action: "*"` on `Resource: "*"`. [`pipeline/cfn-execution-role.yaml`](pipeline/cfn-execution-role.yaml) creates a role that can run only the DynamoDB actions the table needs, only on `dynamodb-sam-lab-<env>-*`, and that only CloudFormation in this account can assume. It's passed to bootstrap with `--cloudformation-execution-role`, so SAM doesn't create its admin role and the pipeline role's `iam:PassRole` is limited to ours. |
| No `SSESpecification` on the table | DynamoDB always encrypts at rest. Leaving the property out keeps the free AWS-owned key. `SSEEnabled: true` would switch to the AWS-managed KMS key and require KMS permissions on the deploy role. Policy-as-code rules such as `DYNAMODB_TABLE_MUST_BE_ENCRYPTED` flag the missing property, but the table is still encrypted. |
| GitHub OIDC instead of access keys | No long-lived AWS credentials are stored in GitHub. Each stage's role trusts only its own branch. |
| `validate` job before `deploy` | A template that fails lint never reaches the step that gets AWS credentials. Only the deploy job has `id-token: write`. |
| No `environment:` key on the deploy job | Setting one changes the OIDC subject claim to `…:environment:<name>`, which wouldn't match the branch-scoped trust policy that `sam pipeline bootstrap` creates. |
| `concurrency` with `cancel-in-progress: false` | Deployments queue rather than cancel, so a CloudFormation update is never interrupted mid-flight. |

## Repo layout

```text
template.yaml                      # SAM template: the Tasks table
samconfig.toml                     # Per-environment config ([dev.*] / [prod.*])
scripts/bootstrap-pipeline.sh      # One-time: deploy role stacks + sam pipeline bootstrap for dev + prod
pipeline/cfn-execution-role.yaml   # Least-privilege CloudFormation execution role (one stack per env)
.github/workflows/
  deploy-dev.yml                   # push to develop -> deploys the dev stack only
  deploy-prod.yml                  # push to main    -> deploys the prod stack only
docs/sample-items.json             # Sample items for console CRUD testing
docs/sam-pipeline-init/            # Unmodified output of `sam pipeline init` (not run; kept as evidence)
```

## Pipeline design

| Environment | Branch    | Workflow          | Stack                   | Artifacts bucket            |
|-------------|-----------|-------------------|-------------------------|-----------------------------|
| dev         | `develop` | `deploy-dev.yml`  | `dynamodb-sam-lab-dev`  | bucket from `--stage dev`   |
| prod        | `main`    | `deploy-prod.yml` | `dynamodb-sam-lab-prod` | bucket from `--stage prod`  |

- `sam pipeline bootstrap` runs once per stage. Each stage gets its own artifacts bucket,
  pipeline execution role, and CloudFormation execution role.
- This repo doesn't use `sam pipeline init`'s single multi-stage workflow. It has two
  hand-written workflows, one per environment, and each one deploys only its own stack with
  only its own stage's variables.
- Workflows trigger only when `template.yaml`, `samconfig.toml`, or their own workflow file
  changes. Both can also be run by hand (`workflow_dispatch`).

### From `sam pipeline init` to two pipelines

`sam pipeline init` (GitHub Actions, two-stage template, with the `dev` and `prod` stages from
bootstrap) generated
[`docs/sam-pipeline-init/pipeline.generated.yaml`](docs/sam-pipeline-init/pipeline.generated.yaml).
It's kept unmodified outside `.github/workflows/` so it never runs. It was split into the two
workflows like this:

| Generated (`pipeline.yaml`) | Split into |
| --- | --- |
| One workflow on `main` that deploys testing, then prod | `deploy-dev.yml` on `develop`, `deploy-prod.yml` on `main` |
| `env:` block with both stages' role ARNs and buckets | `DEV_*` variables used only in `deploy-dev.yml`, `PROD_*` only in `deploy-prod.yml` |
| `test` job (empty placeholder) | `validate` job: `sam validate --lint`, with no AWS credentials |
| `build-and-package` + `deploy-testing` | `deploy-dev.yml` → `deploy` job |
| `build-and-package` + `deploy-prod` | `deploy-prod.yml` → `deploy` job |
| `build-and-deploy-feature` / `delete-feature` | Dropped. No per-branch stacks for a single-table lab. |

The generated file also couldn't deploy this project as-is, which is another reason for the
split:

- **Wrong branch for the dev role.** Its testing deploy runs from `main`, but the dev role
  trusts only `develop`, so `AssumeRoleWithWebIdentity` would be denied.
- **Wrong capability.** It passes `CAPABILITY_IAM`, but the template's transforms need
  `CAPABILITY_AUTO_EXPAND`.
- **Missing parameter.** It never sets `Environment`, which has no default. The split workflows
  take it from `samconfig.toml` via `--config-env`.
- **Both environments' credentials in one run.** One run from `main` assumes the dev and prod
  roles. Each split workflow can only reach its own environment.

## Setup

Prerequisites: the AWS CLI v2, [SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html),
the GitHub CLI, and admin credentials for the target account.

1. **One-time:** bootstrap both pipeline stages:

   ```bash
   ./scripts/bootstrap-pipeline.sh
   ```

2. **One-time:** from `.aws-sam/pipeline/pipelineconfig.toml`, set these GitHub repo
   **variables** (Settings → Secrets and variables → Actions → Variables):

   | Variable                                        | Source (stage `dev` / `prod`)   |
   |-------------------------------------------------|---------------------------------|
   | `DEV_REGION` / `PROD_REGION`                    | `region`                        |
   | `DEV_PIPELINE_EXECUTION_ROLE` / `PROD_…`        | `pipeline_execution_role`       |
   | `DEV_CLOUDFORMATION_EXECUTION_ROLE` / `PROD_…`  | `cloudformation_execution_role` |
   | `DEV_ARTIFACTS_BUCKET` / `PROD_…`               | `artifacts_bucket`              |

   Or set them from the file with the GitHub CLI:

   ```bash
   CFG=.aws-sam/pipeline/pipelineconfig.toml
   get() { sed -n "/^\[$1\.pipeline_bootstrap/,/^\[/p" $CFG | grep "^$2 =" | cut -d'"' -f2; }
   for s in dev prod; do
     P=$(echo $s | tr a-z A-Z)
     gh variable set ${P}_REGION                        --body "$(get $s region)"
     gh variable set ${P}_PIPELINE_EXECUTION_ROLE       --body "$(get $s pipeline_execution_role)"
     gh variable set ${P}_CLOUDFORMATION_EXECUTION_ROLE --body "$(get $s cloudformation_execution_role)"
     gh variable set ${P}_ARTIFACTS_BUCKET              --body "$(get $s artifacts_bucket)"
   done
   ```

3. Check that each stage's role trusts only its own branch:

   ```bash
   for s in dev prod; do
     ROLE=$(aws cloudformation describe-stack-resource \
       --stack-name aws-sam-cli-managed-$s-pipeline-resources \
       --logical-resource-id PipelineExecutionRole \
       --query StackResourceDetail.PhysicalResourceId --output text)
     echo "== $s: $(aws iam get-role --role-name "$ROLE" \
       --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.*."token.actions.githubusercontent.com:sub"' --output text)"
   done
   # == dev: repo:Eric-Obeng@61484602/dynamodb-sam-lab@1415454330:ref:refs/heads/develop
   # == prod: repo:Eric-Obeng@61484602/dynamodb-sam-lab@1415454330:ref:refs/heads/main
   ```

4. Commit `.aws-sam/pipeline/pipelineconfig.toml` and push to `develop`. That deploys dev.
   Open a PR from `develop` to `main` and merge it. That deploys prod.

### SAM CLI quirks (handled in `scripts/bootstrap-pipeline.sh`)

Found with SAM CLI 1.168.0:

- **`--cicd-provider` is required with `--oidc-provider`.** Without it, SAM resets the OIDC
  provider to nothing and fails with `Missing required parameter '--oidc-provider'`.
- **Saved values override the command line.** SAM saves `deployment_branch`, `github_org` and
  `github_repo` under `[default]` in `pipelineconfig.toml`, and on later runs uses them even when
  the matching flags are passed. Without a fix, the prod role would trust `develop`, and a re-run
  would lose the immutable-subject IDs (see the next point). The script resets all three before
  each stage, and step 3 above checks the result.
- **SAM doesn't know GitHub's immutable OIDC subjects.** This repo's tokens carry
  `repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:…`, but SAM writes a name-only trust
  (`repo:<owner>/<repo>:ref:…`), so `AssumeRoleWithWebIdentity` is denied. The script reads
  the repo's subject prefix with `gh api` and passes the ID form as `--github-org` /
  `--github-repo`. Matching on IDs is also safer: a deleted or renamed repo can't be
  recreated under the same name to gain the role.
- **On Windows (Git Bash)** the SAM installer only provides `sam.cmd`. The script uses it when
  `sam` isn't on the path.

### Local checks

```bash
sam validate --config-env dev     # validate + cfn-lint
sam build    --config-env dev
```

## Verification (console CRUD)

1. Go to DynamoDB → Tables → `dynamodb-sam-lab-dev-tasks`. Check that the capacity mode is
   *On-demand*, the table class is *DynamoDB Standard-IA*, and the **Indexes** tab lists
   `StatusIndex` and `AssigneeIndex`.
2. **Create:** Explore items → Create item → JSON view, then paste an item from
   `docs/sample-items.json` (the file uses DynamoDB JSON, so keep *View DynamoDB JSON* on).
3. **Read:**
   - Scan the table to see every item.
   - Query `StatusIndex` with `status = TODO`.
   - Query `AssigneeIndex` with `assignee = eric`.
4. **Update:** open an item and change `status` to `DONE`, then re-run the `StatusIndex`
   query to see it move.
5. **Delete:** select an item → Actions → Delete items.

## Rubric evidence

| Rubric item | Points | Where |
| --- | --- | --- |
| DynamoDB defined in SAM template | 10 | [`template.yaml`](template.yaml), `TasksTable` |
| On-Demand billing | 5 | `BillingMode: PAY_PER_REQUEST` |
| Non-Standard table class | 5 | `TableClass: STANDARD_INFREQUENT_ACCESS` |
| Primary key + 2 attributes + 2 GSIs | 20 | `taskId`; `title`, `priority` (+4 more); `StatusIndex`, `AssigneeIndex` |
| SAM pipeline configured | 10 | [`scripts/bootstrap-pipeline.sh`](scripts/bootstrap-pipeline.sh), [`pipelineconfig.toml`](.aws-sam/pipeline/pipelineconfig.toml), least-privilege roles in [`pipeline/cfn-execution-role.yaml`](pipeline/cfn-execution-role.yaml) |
| GitHub Actions workflow functioning | 10 | [Actions tab](https://github.com/Eric-Obeng/dynamodb-sam-lab/actions) |
| Multi-environment (dev/prod) | 10 | `[dev.*]` / `[prod.*]` in [`samconfig.toml`](samconfig.toml), one stack per environment |
| Console CRUD | 10 | [Verification](#verification-console-crud) |
| **Bonus:** environment-scoped artifact buckets | 10 | Separate bucket per `--stage`, passed as `DEV_ARTIFACTS_BUCKET` / `PROD_ARTIFACTS_BUCKET` |
| **Bonus:** separate dev and prod pipelines | 10 | Generated [`pipeline.generated.yaml`](docs/sam-pipeline-init/pipeline.generated.yaml) split into [`deploy-dev.yml`](.github/workflows/deploy-dev.yml) and [`deploy-prod.yml`](.github/workflows/deploy-prod.yml); see [the mapping](#from-sam-pipeline-init-to-two-pipelines) |

## Teardown and cost

On-demand billing with no traffic costs nothing beyond storage (a few cents for the sample
items). To remove everything:

```bash
sam delete --config-env dev --no-prompts
# prod: turn off deletion protection on the table first; the table is retained
# by DeletionPolicy, so delete it from the console after the stack is gone.
sam delete --config-env prod --no-prompts
# pipeline resources (empty the artifacts buckets first):
aws cloudformation delete-stack --stack-name aws-sam-cli-managed-dev-pipeline-resources
aws cloudformation delete-stack --stack-name aws-sam-cli-managed-prod-pipeline-resources
# least-privilege role stacks (after the stacks above are gone):
aws cloudformation delete-stack --stack-name dynamodb-sam-lab-dev-cfn-execution-role
aws cloudformation delete-stack --stack-name dynamodb-sam-lab-prod-cfn-execution-role
```
