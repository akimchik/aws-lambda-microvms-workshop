import json
import threading
import boto3
import os
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler

class RunnerHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else "{}"
        
        if self.path == '/run':
            data = json.loads(body)
            
            # Return 202 immediately (Fire-and-forget handoff)
            self.send_response(202)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status": "accepted"}')
            
            # Run autonomous CI pipeline in background
            threading.Thread(target=self.run_ci, args=(data,)).start()
        else:
            self.send_response(200)
            self.end_headers()

    def run_ci(self, data):
        repo_name = data.get("repo_name")
        branch = data.get("branch")
        pr_id = data.get("pr_id")
        commit_id = data.get("commit_id")
        region = os.environ.get("AWS_REGION", "us-east-1")
        
        print(f"[INFO] cloning {repo_name} branch {branch}")
        client = boto3.client('codecommit', region_name=region)
        
        exit_code = 0
        try:
            # 1. Clone using git-remote-codecommit
            subprocess.check_output(
                ["git", "clone", f"codecommit::{region}://{repo_name}", "/tmp/repo"],
                stderr=subprocess.STDOUT
            )
            
            # 2. Checkout
            subprocess.check_output(
                ["git", "checkout", branch],
                cwd="/tmp/repo",
                stderr=subprocess.STDOUT
            )
            
            # 3. Run pipeline
            print("[INFO] running ci/steps.sh")
            log_bytes = subprocess.check_output(
                ["bash", "ci/steps.sh"],
                cwd="/tmp/repo",
                stderr=subprocess.STDOUT
            )
            log = log_bytes.decode('utf-8')
            msg = f"CI build passed (exit code 0)\n\n```\n{log}\n```"
            print(f"[INFO] posted passed result to PR {pr_id}")
        except subprocess.CalledProcessError as e:
            exit_code = e.returncode
            log = e.output.decode('utf-8') if e.output else str(e)
            msg = f"CI build failed (exit code {exit_code})\n\n```\n{log}\n```"
            print(f"[INFO] posted failed result to PR {pr_id}")
        except Exception as e:
            exit_code = 1
            msg = f"CI build crashed\n\n```\n{str(e)}\n```"
            print(f"[ERROR] crash: {msg}")

        # 4. Post comment to PR
        try:
            pr_data = client.get_pull_request(pullRequestId=pr_id)['pullRequest']
            target = pr_data['pullRequestTargets'][0]
            
            client.post_comment_for_pull_request(
                pullRequestId=pr_id,
                repositoryName=repo_name,
                beforeCommitId=target['destinationCommit'],
                afterCommitId=target['sourceCommit'],
                content=msg
            )
        except Exception as e:
            print("[ERROR] Failed to post PR comment:", e)

def run_server():
    server = HTTPServer(('0.0.0.0', 9000), RunnerHandler)
    print('[INFO] CI runner listening on 0.0.0.0:9000', flush=True)
    server.serve_forever()

if __name__ == '__main__':
    run_server()
