IMAGE_ARN=$(cat saas-image.sh | grep -o 'arn:aws:lambda[^"]*')
aws lambda-microvms get-microvm-image --image-identifier "$IMAGE_ARN" --region us-east-1
