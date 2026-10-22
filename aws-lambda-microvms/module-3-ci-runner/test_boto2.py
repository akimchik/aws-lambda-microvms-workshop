import boto3
from botocore.stub import Stubber

client = boto3.client('codecommit', region_name='us-east-1')
stubber = Stubber(client)

stubber.add_response('create_pull_request', {'pullRequest': {'pullRequestId': '1'}}, {
    'title': 'CI pipeline: feature/ci-pipeline',
    'description': 'Automated PR for CI testing',
    'targets': [{
        'repositoryName': 'test',
        'sourceReference': 'feature/ci-pipeline',
        'destinationReference': 'main'
    }]
})
stubber.activate()
client.create_pull_request(
    title='CI pipeline: feature/ci-pipeline',
    description='Automated PR for CI testing',
    targets=[{
        'repositoryName': 'test',
        'sourceReference': 'feature/ci-pipeline',
        'destinationReference': 'main'
    }]
)
stubber.deactivate()
print("create_pull_request params valid!")
