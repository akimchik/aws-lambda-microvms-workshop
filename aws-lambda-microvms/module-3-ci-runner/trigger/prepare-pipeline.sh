#!/bin/bash
set -e

REPO_NAME="lambda-mvm-workshop-code-review"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "==> configuring git credential helper for CodeCommit"
git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true

echo "==> cloning ${REPO_NAME} and checking out feature/ci-pipeline"
rm -rf /tmp/ci-demo
git -c credential.helper="" -c credential.helper='!aws codecommit credential-helper $@' -c credential.UseHttpPath=true clone https://git-codecommit.${AWS_REGION}.amazonaws.com/v1/repos/${REPO_NAME} /tmp/ci-demo
cd /tmp/ci-demo
git checkout -b feature/ci-pipeline || git checkout feature/ci-pipeline

echo "==> writing ci/steps.sh"
mkdir -p ci src tests
cat << 'EOF' > ci/steps.sh
#!/usr/bin/env bash
set -e
echo "== compile =="
python3 -m compileall -q src
echo "== test =="
python3 -m unittest discover -s tests -p 'test_*.py'
EOF
chmod +x ci/steps.sh

cat << 'EOF' > src/calculator.py
def add(a, b):
    return a + b
EOF

cat << 'EOF' > tests/test_calculator.py
import unittest
from src.calculator import add
class TestCalculator(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 3), 5)
if __name__ == "__main__":
    unittest.main()
EOF

echo "Repo ready at /tmp/ci-demo on branch feature/ci-pipeline, with the pipeline and sample code written for you to commit."
echo "Next, run these git commands yourself to fire the runner:"
echo "cd /tmp/ci-demo"
echo "git add ci src tests"
echo "git commit -m 'Add CI pipeline and calculator module'"
echo "git push origin feature/ci-pipeline --force"
