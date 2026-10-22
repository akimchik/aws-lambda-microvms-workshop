import boto3
from botocore.stub import Stubber

client = boto3.client('codecommit', region_name='us-east-1')
stubber = Stubber(client)

# Test post_comment_for_pull_request
stubber.add_response('post_comment_for_pull_request', {}, {
    'pullRequestId': '1',
    'repositoryName': 'test',
    'beforeCommitId': 'aaa',
    'afterCommitId': 'bbb',
    'content': 'test'
})
stubber.activate()
client.post_comment_for_pull_request(
    pullRequestId='1',
    repositoryName='test',
    beforeCommitId='aaa',
    afterCommitId='bbb',
    content='test'
)
stubber.deactivate()
print("CodeCommit params valid!")
