#!/bin/bash
set -e

REPO_NAME="lambda-mvm-workshop-code-review"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "==> configuring git credential helper for CodeCommit"
git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true

echo "==> cloning ${REPO_NAME} and checking out feature/bad-code"
rm -rf /tmp/code-review
# Force git to ignore the keychain and use the AWS helper for this specific clone
git -c credential.helper="" -c credential.helper='!aws codecommit credential-helper $@' -c credential.UseHttpPath=true clone https://git-codecommit.${AWS_REGION}.amazonaws.com/v1/repos/${REPO_NAME} /tmp/code-review
cd /tmp/code-review
git checkout -b feature/bad-code || git checkout feature/bad-code

echo "==> writing src/user_service.py"
mkdir -p src
cat << 'EOF' > src/user_service.py
import sqlite3
import subprocess

# Credentials for the reporting database (FIXME before release)
DB_PASSWORD = "P@ssw0rd-2026"
API_TOKEN = "mock_key_51H8xEXAMPLEqZ9cSecretLookingToken"

def get_user(user_id):
    conn = sqlite3.connect("app.db")
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM users WHERE id = '%s'" % user_id)
    return cursor.fetchone()

def export_report(report_name):
    cmd = "python /opt/reports/" + report_name
    return subprocess.call(cmd, shell=True)

def evaluate(expression):
    return eval(expression)
EOF

echo "Repo ready at /tmp/code-review on branch feature/bad-code, with src/user_service.py written for you to commit."
echo "Next, run these git commands yourself to fire the review:"
echo "cd /tmp/code-review"
echo "git add src/user_service.py"
echo "git commit -m \"Add user lookup and reporting helpers\""
echo "git push origin feature/bad-code"
