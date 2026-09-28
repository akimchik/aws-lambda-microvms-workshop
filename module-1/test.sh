MICROVM_ID="YOUR-MICROVM-ID"
ENDPOINT="YOUR-ENDPOINT"

# Generate Token
AUTH_TOKEN=$(aws lambda-microvms create-microvm-auth-token \
    --microvm-identifier "$MICROVM_ID" \
    --region us-east-1 \
    --expiration-in-minutes 60 \
    --allowed-ports allPorts={} \
    --query 'authToken."X-aws-proxy-auth"' --output text)

# Test the execution
curl -X POST "https://${ENDPOINT}/execute" \
    -H "X-aws-proxy-auth: ${AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"code": "print(\"Hello from inside a Lambda MicroVM!\")\nprint(2 + 2)"}'
