from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "0.0.0.0"
PORT = 8000


class HelloHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write("Привет!".encode("utf-8"))
        print(f"Запрос от {self.client_address[0]} на {self.path}")

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), HelloHandler)
    print(f"Сайт запущен на http://localhost:{PORT}")
    server.serve_forever()
