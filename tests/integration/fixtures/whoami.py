# The traffic oracle of the integration lab: answers with the source
# address it observed. Through-tunnel requests arrive with the endpoint's
# IP as source, direct requests with the caller's own IP — one server,
# two assertions.
from http.server import BaseHTTPRequestHandler, HTTPServer


class Whoami(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"REMOTE_ADDR=" + self.client_address[0].encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


HTTPServer(("0.0.0.0", 8080), Whoami).serve_forever()
