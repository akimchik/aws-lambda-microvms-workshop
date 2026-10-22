#!/bin/bash
set -e

# Make sure you are in module-1 directory
cd "$(dirname "$0")"

# IMPORTANT: Set these to the values provided in your workshop output
S3_BUCKET="lambda-mvm-workshop-artifacts-387411579638"
AWS_REGION=${AWS_REGION:-"us-east-1"}
AWS_ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)

echo "Packaging application..."
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
S3_KEY="deployments/app-${TIMESTAMP}.zip"
zip -r app.zip .

echo "Uploading to S3..."
aws s3 cp app.zip s3://${S3_BUCKET}/${S3_KEY} --region $AWS_REGION

echo "Creating MicroVM Image..."
RESP=$(aws lambda-microvms create-microvm-image \
    --name "mvm-code-execution-sandbox" \
    --code-artifact "uri=s3://${S3_BUCKET}/${S3_KEY}" \
    --base-image-arn "arn:aws:lambda:${AWS_REGION}:aws:microvm-image:al2023-1" \
    --build-role-arn "arn:aws:iam::${AWS_ACCOUNTID}:role/LambdaMicroVMBuildRole-workshop" \
    --region $AWS_REGION \
    --logging '{"cloudWatch":{"logGroup":"/aws/mvm-code-execution-sandbox/mvm-code-execution-sandbox"}}')

IMAGE_ARN=$(echo $RESP | jq -r '.imageArn')
echo "Image ARN: $IMAGE_ARN"

echo ""
echo "Verify image status with:"
echo "aws lambda-microvms get-microvm-image --image-identifier ${IMAGE_ARN} --region $AWS_REGION"
