#!/bin/bash
set -e

if [ -f ../runner/ci-runner-image.sh ]; then
    source ../runner/ci-runner-image.sh
fi
IMAGE_ARN="${CI_IMAGE_ARN:-YOUR_IMAGE_ARN}"
AWS_ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)
DURABLE_ORCHESTRATOR_ROLE_ARN="${DURABLE_ORCHESTRATOR_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNTID}:role/DurableOrchestratorRole}"

echo "Building orchestrator..."
sam build

echo "Deploying orchestrator..."
sam deploy \
    --parameter-overrides \
        ImageArn=$IMAGE_ARN \
        FunctionName=${FUNCTION_NAME:-ci-runner-orchestrator} \
        OrchestratorRoleArn=${DURABLE_ORCHESTRATOR_ROLE_ARN}

echo "Deploy complete. The 'live' alias now points at the just-published version."
