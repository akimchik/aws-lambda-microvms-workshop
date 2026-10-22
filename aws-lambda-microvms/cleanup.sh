#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-us-east-1}"

echo "Cleaning up Module 4 SaaS Control Plane..."
aws cloudformation delete-stack --stack-name saas-control-plane --region $AWS_REGION
aws cloudformation wait stack-delete-complete --stack-name saas-control-plane --region $AWS_REGION
echo "Module 4 stack deleted."

echo "Cleaning up Module 3 CI Orchestrator..."
aws cloudformation delete-stack --stack-name module3-orchestrator --region $AWS_REGION
aws cloudformation wait stack-delete-complete --stack-name module3-orchestrator --region $AWS_REGION
echo "Module 3 stack deleted."

echo "Cleaning up dangling MicroVMs..."
# Fetch all RUNNING or SUSPENDED microvms
VM_IDS=$(aws lambda-microvms list-microvms --region $AWS_REGION --query 'microvms[?state==`RUNNING` || state==`SUSPENDED`].microvmId' --output text)

for vm in $VM_IDS; do
    if [ "$vm" != "None" ] && [ -n "$vm" ]; then
        echo "Terminating $vm..."
        aws lambda-microvms terminate-microvm --microvm-identifier "$vm" --region $AWS_REGION
    fi
done

echo "Cleanup complete! All workshop resources have been torn down."
