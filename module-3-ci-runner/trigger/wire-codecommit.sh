#!/bin/bash
set -e

REPO_NAME="lambda-mvm-workshop-code-review"
FUNCTION_NAME="${FUNCTION_NAME:-ci-runner-orchestrator}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)

echo "==> granting CodeCommit permission to invoke the function"
aws lambda add-permission \
    --function-name "${FUNCTION_NAME}:live" \
    --statement-id CodeCommitInvokeCI \
    --action lambda:InvokeFunction \
    --principal codecommit.amazonaws.com \
    --source-arn "arn:aws:codecommit:${AWS_REGION}:${AWS_ACCOUNTID}:${REPO_NAME}" \
    --region $AWS_REGION >/dev/null || true

echo "==> registering repository trigger"
aws codecommit put-repository-triggers \
    --repository-name $REPO_NAME \
    --triggers "[{\"name\":\"ci-runner-trigger\",\"destinationArn\":\"arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNTID}:function:${FUNCTION_NAME}:live\",\"events\":[\"all\"],\"branches\":[\"feature/ci-pipeline\"]}]" \
    --region $AWS_REGION

echo "==> testing the trigger"
aws codecommit test-repository-triggers \
    --repository-name $REPO_NAME \
    --triggers "[{\"name\":\"ci-runner-trigger\",\"destinationArn\":\"arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNTID}:function:${FUNCTION_NAME}:live\",\"events\":[\"all\"],\"branches\":[\"feature/ci-pipeline\"]}]" \
    --region $AWS_REGION

echo "Trigger wired. A push to feature/ci-pipeline on ${REPO_NAME} will now invoke the CI runner orchestrator."
