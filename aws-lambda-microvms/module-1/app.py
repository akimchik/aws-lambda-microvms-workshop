import json
import sys
import threading
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler

class HookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else "{}"
        
        # Log the hook
        print(f"HOOK {self.command} {self.path} {self.protocol_version}", flush=True)
        
        # All hooks return 200 OK
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{}')

class AppHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        print(f"APP {self.command} {self.path} {self.protocol_version}", flush=True)
        
        if self.path == '/execute':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8')
            try:
                data = json.loads(body)
                code = data.get('code', '')
                
                # Execute the code in a subprocess
                result = subprocess.run(
                    [sys.executable, "-c", code],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                
                response = {
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "exit_code": result.returncode,
                    "success": result.returncode == 0
                }
            except Exception as e:
                response = {
                    "stdout": "",
                    "stderr": str(e),
                    "exit_code": -1,
                    "success": False
                }
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode('utf-8'))
        elif self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "I'm here!"}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

def run_hooks():
    server = HTTPServer(('0.0.0.0', 9000), HookHandler)
    print('Lifecycle hook server listening on port 9000', flush=True)
    server.serve_forever()

def run_app():
    server = HTTPServer(('0.0.0.0', 8080), AppHandler)
    print('Code execution API listening on port 8080', flush=True)
    server.serve_forever()

if __name__ == '__main__':
    t1 = threading.Thread(target=run_hooks, daemon=True)
    t2 = threading.Thread(target=run_app, daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
