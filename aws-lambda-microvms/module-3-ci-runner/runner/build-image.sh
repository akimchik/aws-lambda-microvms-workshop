#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)
S3_BUCKET="${ARTIFACTS_BUCKET:-lambda-mvm-workshop-artifacts-$AWS_ACCOUNTID}"
MODULE2_REVIEWER_BUILD_ROLE_ARN="${MODULE2_REVIEWER_BUILD_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNTID}:role/Module2ReviewerBuildRole-workshop}"

echo "==> creating microvm image"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
S3_KEY="deployments/ci-runner-${TIMESTAMP}.zip"
zip -r runner.zip app.py Dockerfile >/dev/null
aws s3 cp runner.zip s3://${S3_BUCKET}/${S3_KEY} --region $AWS_REGION >/dev/null

RESP=$(aws lambda-microvms create-microvm-image \
    --name "mvm-ci-runner" \
    --code-artifact "uri=s3://${S3_BUCKET}/${S3_KEY}" \
    --base-image-arn "arn:aws:lambda:${AWS_REGION}:aws:microvm-image:al2023-1" \
    --build-role-arn "${MODULE2_REVIEWER_BUILD_ROLE_ARN}" \
    --region $AWS_REGION)

IMAGE_ARN=$(echo $RESP | jq -r '.imageArn')
echo "==> waiting for build to complete (typically 90-120s)"

while true; do
    STATE=$(aws lambda-microvms get-microvm-image --image-identifier "$IMAGE_ARN" --region $AWS_REGION --query 'state' --output text)
    echo "state=$STATE"
    if [ "$STATE" == "SUCCESSFUL" ] || [ "$STATE" == "CREATED" ]; then
        break
    elif [ "$STATE" == "CREATE_FAILED" ] || [ "$STATE" == "FAILED" ]; then
        echo "Build failed!"
        exit 1
    fi
    sleep 5
done

echo "Runner image built: $IMAGE_ARN"
echo "export CI_IMAGE_ARN=$IMAGE_ARN" > ci-runner-image.sh
echo "Persisted to ci-runner-image.sh for future shells."
