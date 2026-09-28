import boto3

client = boto3.client('codecommit', region_name='us-east-1')
try:
    comments = client.get_comments_for_pull_request(pullRequestId='2')
    for c in comments.get('commentsForPullRequestData', []):
        for comment in c.get('comments', []):
            print(f"COMMENT: {comment['content']}")
except Exception as e:
    print(f"Error checking PR: {e}")
