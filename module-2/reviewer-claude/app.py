import json
import threading
import boto3
from http.server import HTTPServer, BaseHTTPRequestHandler
import os

class HookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else "{}"
        
        if self.path == '/review':
            data = json.loads(body)
            callback_id = data.get('callback_id')
            
            # Return 202 immediately as requested by the architecture
            self.send_response(202)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "accepted"}).encode('utf-8'))
            
            # Run review asynchronously
            threading.Thread(target=self.run_review, args=(data, callback_id)).start()
        else:
            # Standard lifecycle hooks return 200
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{}')

    def run_review(self, data, callback_id):
        client = boto3.client('lambda')
        try:
            # Simulate the Claude Code review process
            # (In reality, this would invoke Amazon Bedrock with Claude Sonnet 4.6)
            review_payload = {
                "review": "SECURITY WARNING: hardcoded credentials, SQL injection vulnerability with string formatting, shell=True command execution, and unsafe eval() detected."
            }
            
            # Call back to the Durable Orchestrator
            client.send_durable_execution_callback_success(
                CallbackId=callback_id,
                Output=json.dumps(review_payload)
            )
        except Exception as e:
            client.send_durable_execution_callback_failure(
                CallbackId=callback_id,
                Error="ReviewFailed",
                Cause=str(e)
            )

def run_server():
    server = HTTPServer(('0.0.0.0', 9000), HookHandler)
    print('Reviewer API listening on port 9000', flush=True)
    server.serve_forever()

if __name__ == '__main__':
    run_server()
