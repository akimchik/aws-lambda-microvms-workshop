#!/bin/bash
set -e

# Accept Image ARN as a command line argument
IMAGE_ARN="${1:-YOUR_IMAGE_ARN}"

if [[ "$IMAGE_ARN" != arn:* ]]; then
    echo "Error: You must provide a valid Image ARN starting with 'arn:'"
    echo "Usage: ./launch_microvm.sh <IMAGE_ARN>"
    exit 1
fi

AWS_REGION=${AWS_REGION:-"us-east-1"}
AWS_ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)

echo "Launching MicroVM..."
RESP=$(aws lambda-microvms run-microvm \
    --image-identifier "${IMAGE_ARN}" \
    --image-version "1.0" \
    --ingress-network-connectors "arn:aws:lambda:${AWS_REGION}:aws:network-connector:aws-network-connector:HTTP_INGRESS" \
    --egress-network-connectors "arn:aws:lambda:${AWS_REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS" \
    --execution-role-arn "arn:aws:iam::${AWS_ACCOUNTID}:role/LambdaMicroVMExecutionRole-workshop" \
    --idle-policy "autoResumeEnabled=true,maxIdleDurationSeconds=900,suspendedDurationSeconds=300" \
    --region $AWS_REGION \
    --logging '{"cloudWatch":{"logGroup":"/aws/lambda-microvms/mvm-code-execution-sandbox"}}')

MICROVM_ID=$(echo $RESP | jq -r '.microvmId')
ENDPOINT=$(echo $RESP | jq -r '.endpoint')

echo "MicroVM ID: $MICROVM_ID"
echo "Endpoint: $ENDPOINT"
echo ""

echo "Waiting 3 seconds for VM to be ready..."
sleep 3

echo ""
echo "Generating Auth Token..."
AUTH_TOKEN=$(aws lambda-microvms create-microvm-auth-token \
    --microvm-identifier "$MICROVM_ID" \
    --region $AWS_REGION \
    --expiration-in-minutes 60 \
    --allowed-ports allPorts={} \
    --query 'authToken."X-aws-proxy-auth"' --output text)

echo "Auth Token: $AUTH_TOKEN"
echo ""

echo "Verifying /health endpoint on port 9000..."
curl -X POST "https://${ENDPOINT}/health" \
    -H "X-aws-proxy-auth: ${AUTH_TOKEN}" \
    -H "X-aws-proxy-port: 9000"

echo -e "\n\nRunning code execution on port 8080..."
curl -X POST "https://${ENDPOINT}/execute" \
    -H "X-aws-proxy-auth: ${AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"code": "print(\"Hello from inside a Lambda MicroVM!\")\nprint(2 + 2)"}'
echo ""
