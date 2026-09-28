#!/bin/bash
set -e

if [ -f ../tenant-app/saas-image.sh ]; then
    source ../tenant-app/saas-image.sh
fi
IMAGE_ARN="${SAAS_IMAGE_ARN:-YOUR_IMAGE_ARN}"
AWS_ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)
DURABLE_ORCHESTRATOR_ROLE_ARN="${DURABLE_ORCHESTRATOR_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNTID}:role/DurableOrchestratorRole}"
MVM_EXECUTION_ROLE_ARN="${MVM_EXECUTION_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNTID}:role/Module2ReviewerBuildRole-workshop}"

echo "Building control plane..."
sam build

echo "Deploying control plane..."
sam deploy \
    --parameter-overrides \
        ImageArn=$IMAGE_ARN \
        OrchestratorRoleArn=${DURABLE_ORCHESTRATOR_ROLE_ARN} \
        ExecutionRoleArn=${MVM_EXECUTION_ROLE_ARN}

echo "Deploy complete."
