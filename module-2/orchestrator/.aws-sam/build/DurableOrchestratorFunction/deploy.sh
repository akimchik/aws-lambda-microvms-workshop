#!/bin/bash
set -e
if [ -f ../reviewer-claude/mvm-image-arn.sh ]; then
    source ../reviewer-claude/mvm-image-arn.sh
fi
IMAGE_ARN="${IMAGE_ARN:-YOUR_IMAGE_ARN}"

AWS_ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)
DURABLE_ORCHESTRATOR_ROLE_ARN="${DURABLE_ORCHESTRATOR_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNTID}:role/DurableOrchestratorRole}"

echo "Building durable orchestrator..."
sam build

echo "Deploying durable orchestrator..."
sam deploy \
    --parameter-overrides \
        ImageArn=$IMAGE_ARN \
        FunctionName=${FUNCTION_NAME:-durable-orchestrator} \
        DurableOrchestratorRoleArn=${DURABLE_ORCHESTRATOR_ROLE_ARN}

echo "Deploy complete. The 'live' alias now points at the just-published version."
