"""MCP protocol and HTTP boundary tests; never connect to a physical device."""

import base64
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "iphonemirror_mcp.py"
spec = importlib.util.spec_from_file_location("iphonemirror_mcp", SCRIPT)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
PNG = base64.b64encode(b"\x89PNG\r\n\x1a\nfixture").decode("ascii")


def request(method, params=None, request_id=1):
    return {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}}


def initialize(server, version="2025-11-25"):
    result = server.handle(request("initialize", {
        "protocolVersion": version, "capabilities": {},
        "clientInfo": {"name": "test", "version": "1"},
    }))
    server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})
    return result


class FakeAPI:
    def __init__(self):
        self.calls = []
        self.timeouts = []
        self.error = None

    def request(self, method, endpoint, payload=None, timeout=None):
        self.calls.append((method, endpoint, payload))
        self.timeouts.append(timeout)
        if self.error:
            raise bridge.BridgeError(self.error)
        if endpoint == "/v1/screenshot":
            return {"image": PNG, "mimeType": "image/png", "width": 100, "height": 200,
                    "sessionID": "current", "observationID": "upright-100x200",
                    "frameID": 42, "ageSeconds": 0.05}
        return {"accepted": True, "sessionID": "current", "note": "queued, not verified"}


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        self.server = bridge.Server(self.api)

    def call(self, name, arguments=None):
        return self.server.handle(request("tools/call", {"name": name, "arguments": arguments or {}}))

    def test_lifecycle_negotiates_versions_and_requires_initialization(self):
        self.assertEqual(self.server.handle(request("tools/list"))["error"]["code"], -32002)
        self.assertEqual(self.server.handle(request("ping"))["result"], {})
        for version in bridge.PROTOCOL_VERSIONS:
            result = initialize(bridge.Server(), version)
            self.assertEqual(result["result"]["protocolVersion"], version)
        result = initialize(self.server, "future-version")
        self.assertEqual(result["result"]["protocolVersion"], bridge.PROTOCOL_VERSIONS[0])
        self.assertEqual(initialize(self.server)["error"]["code"], -32600)

    def test_catalog_and_all_action_mappings(self):
        initialize(self.server)
        catalog = self.server.handle(request("tools/list"))["result"]["tools"]
        self.assertEqual(len(catalog), 16)
        for definition in catalog:
            self.assertFalse(definition["inputSchema"]["additionalProperties"])
        arguments = {
            "tap": {"x": 0.2, "y": 0.3, "duration": 0.5},
            "swipe": {"x": 0.2, "y": 0.3, "toX": 0.4, "toY": 0.8},
            "type": {"text": "hello \U0001f44b"}, "key": {"key": "enter"},
            "rotate": {"direction": "left"}, "button": {"button": "volume_up"},
        }
        for definition in catalog:
            name = definition["name"]
            if definition["annotations"]["readOnlyHint"]:
                continue
            if name in bridge.APP_ENDPOINTS:
                values = {"bundleID": "com.apple.Preferences", "sessionID": "current"}
                self.assertFalse(self.call(name, values)["result"]["isError"])
                self.assertEqual(self.api.calls[-1], ("POST", bridge.APP_ENDPOINTS[name], values))
                self.assertEqual(self.api.timeouts[-1], bridge.APP_REQUEST_TIMEOUT)
                continue
            op = name[7:]
            values = {**arguments.get(op, {}), "sessionID": "current", "observationID": "upright-100x200"}
            response = self.call(name, values)
            self.assertFalse(response["result"]["isError"])
            self.assertEqual(self.api.calls[-1], ("POST", "/v1/actions", {"op": op, **values}))

    def test_app_tools_map_to_app_endpoints(self):
        initialize(self.server)
        self.assertFalse(self.call("iphone_list_apps")["result"]["isError"])
        self.assertFalse(self.call("iphone_list_apps", {"system": True})["result"]["isError"])
        self.assertFalse(self.call("iphone_launch_app", {"bundleID": "com.example.app-1", "restart": True})["result"]["isError"])
        self.assertEqual(self.api.calls, [
            ("GET", "/v1/apps?system=false", None),
            ("GET", "/v1/apps?system=true", None),
            ("POST", "/v1/apps/launch", {"bundleID": "com.example.app-1", "restart": True}),
        ])
        self.assertEqual(self.api.timeouts, [bridge.APP_REQUEST_TIMEOUT] * 3)

    def test_invalid_actions_never_reach_api(self):
        initialize(self.server)
        cases = [
            ("iphone_tap", {"x": True, "y": 0.3}),
            ("iphone_tap", {"x": float("nan"), "y": 0.3}),
            ("iphone_tap", {"x": 10**500, "y": 0.3}),
            ("iphone_tap", {"x": -0.1, "y": 0.3}),
            ("iphone_tap", {"x": 0.1, "y": 0.3, "duration": 3}),
            ("iphone_tap", {"x": 0.1}),
            ("iphone_home", {"extra": "ignored?"}),
            ("iphone_key", {"key": "power"}),
            ("iphone_rotate", {"direction": "up"}),
            ("iphone_button", {}),
            ("iphone_button", {"button": "siri"}),
            ("iphone_type", {"text": ""}),
            ("iphone_type", {"text": "bad\0text"}),
            ("iphone_type", {"text": "\ud800"}),
            ("iphone_type", {"text": "x" * 16001}),
            ("iphone_home", {"sessionID": ""}),
            ("iphone_home", {"observationID": ""}),
            ("iphone_list_apps", {"system": "true"}),
            ("iphone_list_apps", {"system": 1}),
            ("iphone_launch_app", {}),
            ("iphone_launch_app", {"bundleID": ""}),
            ("iphone_launch_app", {"bundleID": "com.x/../y"}),
            ("iphone_launch_app", {"bundleID": "com.x\n"}),
            ("iphone_launch_app", {"bundleID": "a" * 256}),
            ("iphone_launch_app", {"bundleID": "a", "restart": "yes"}),
            ("iphone_launch_app", {"bundleID": "a", "observationID": "x"}),
            ("iphone_terminate_app", {"bundleID": "a", "restart": True}),
        ]
        for name, args in cases:
            with self.subTest(name=name, arguments=str(args)[:100]):
                self.assertTrue(self.call(name, args)["result"]["isError"])
        self.assertEqual(self.api.calls, [])

    def test_screenshot_is_image_with_separate_metadata(self):
        initialize(self.server)
        result = self.call("iphone_screenshot")["result"]
        self.assertFalse(result["isError"])
        text, image = result["content"]
        metadata = json.loads(text["text"])
        self.assertNotIn("image", metadata)
        self.assertEqual(metadata["frameID"], 42)
        self.assertEqual(metadata["observationID"], "upright-100x200")
        self.assertEqual(image, {"type": "image", "mimeType": "image/png", "data": PNG})

    def test_bad_screenshots_and_api_failures_are_tool_errors(self):
        initialize(self.server)
        for value in ({}, {"image": "not-base64", "mimeType": "image/png"},
                      {"image": base64.b64encode(b"text").decode(), "mimeType": "image/png"}):
            with self.subTest(value=value), patch.object(self.api, "request", return_value=value):
                self.assertTrue(self.call("iphone_screenshot")["result"]["isError"])
        self.api.error = "The session changed; observe again."
        result = self.call("iphone_home")["result"]
        self.assertTrue(result["isError"])
        self.assertEqual(result["content"][0]["text"], self.api.error)

    def test_protocol_errors_are_distinct_from_tool_failures(self):
        initialize(self.server)
        self.assertEqual(self.call("unknown")["error"]["code"], -32602)
        self.assertEqual(self.server.handle(request("unknown"))["error"]["code"], -32601)
        self.assertEqual(self.server.handle({"jsonrpc": "2.0", "id": True, "method": "ping"})["error"]["code"], -32600)
        self.assertIsNone(self.server.handle({"jsonrpc": "2.0", "method": "unknown"}))
        self.assertIsNone(self.server.handle({"jsonrpc": "2.0", "id": 9, "result": {}}))

    def test_stdio_recovers_after_malformed_and_oversize_messages(self):
        source = io.BytesIO(b"not json\n" + b"x" * 150 + b"\n" +
                            json.dumps(request("ping")).encode() + b"\n")
        output = io.StringIO()
        with patch.object(bridge, "MAX_MESSAGE_BYTES", 100):
            bridge.serve(self.server, source, output)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([r.get("error", {}).get("code") for r in responses], [-32700, -32600, None])
        self.assertEqual(responses[-1]["result"], {})

    def test_real_process_emits_only_jsonrpc_and_exits_on_eof(self):
        messages = [request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                           "clientInfo": {"name": "test", "version": "1"}}),
                    {"jsonrpc": "2.0", "method": "notifications/initialized"},
                    request("tools/list", request_id=2)]
        process = subprocess.run([sys.executable, "-B", str(SCRIPT)],
                                 input="".join(json.dumps(m) + "\n" for m in messages),
                                 text=True, capture_output=True, timeout=5)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stderr, "")
        responses = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual([r["id"] for r in responses], [1, 2])
        self.assertEqual(len(responses[1]["result"]["tools"]), len(bridge.TOOLS))


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.calls = []
        cls.mode = "ok"

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            def respond(self):
                data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                cls.calls.append((self.command, self.path, dict(self.headers), data))
                if cls.mode == "redirect":
                    self.send_response(302)
                    self.send_header("Location", "http://192.0.2.1/private")
                    result = {"error": "Redirect refused"}
                elif cls.mode == "screenshot":
                    self.send_response(200)
                    result = {"image": PNG, "mimeType": "image/png", "width": 1206, "height": 2624}
                elif cls.mode == "error":
                    self.send_response(409)
                    result = {"error": "Session changed"}
                else:
                    self.send_response(200)
                    result = {"accepted": True}
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b"not-json" if cls.mode == "bad-json" else json.dumps(result).encode())

            def log_message(self, *_):
                pass

        cls.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()
        cls.thread.join()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "automation.json"
        self.origin = f"http://127.0.0.1:{self.http.server_port}"
        self.write_config()
        self.api = bridge.API(self.path)
        type(self).mode = "ok"
        self.calls.clear()

    def write_config(self, url=None, token="test-bearer-token"):
        self.path.write_text(json.dumps({"url": self.origin if url is None else url, "token": token}))

    def test_requests_authenticate_and_refresh_discovery(self):
        with patch.dict(os.environ, {"http_proxy": "http://192.0.2.1:1234", "HTTP_PROXY": "http://192.0.2.1:1234"}):
            self.assertEqual(self.api.request("GET", "/v1/status"), {"accepted": True})
        self.write_config(token="replacement-token")
        self.api.request("POST", "/v1/actions", {"op": "type", "text": "hello \U0001f44b"})
        self.assertEqual(self.calls[0][2]["Authorization"], "Bearer test-bearer-token")
        self.assertEqual(self.calls[1][2]["Authorization"], "Bearer replacement-token")
        self.assertEqual(json.loads(self.calls[1][3])["text"], "hello \U0001f44b")
        self.assertIn(b"\xf0\x9f\x91\x8b", self.calls[1][3])

    def test_cli_full_screenshot_requests_stream_resolution_and_never_overwrites(self):
        type(self).mode = "screenshot"
        output = Path(self.temp.name) / "shot.png"
        command = [sys.executable, "-B", str(SCRIPT), "--discovery", str(self.path),
                   "--screenshot", str(output), "--full"]
        first = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.calls[-1][1], "/v1/screenshot?scale=full")
        self.assertEqual(output.read_bytes(), base64.b64decode(PNG))
        self.assertNotIn("image", json.loads(first.stdout))
        self.assertNotEqual(subprocess.run(command, capture_output=True, timeout=20).returncode, 0)
        full_alone = subprocess.run([sys.executable, "-B", str(SCRIPT), "--full"],
                                    capture_output=True, timeout=20)
        self.assertNotEqual(full_alone.returncode, 0)

    def test_unsafe_discovery_never_opens_connection(self):
        urls = ["http://example.com:80", "http://localhost:80", "https://127.0.0.1:80",
                "http://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:65536",
                "http://127.0.0.1:80/path", "http://127.0.0.1:80?query=1",
                "http://127.0.0.1:80?", "http://127.0.0.1:80#",
                "http://127.0.0.1:80#fragment", "http://name:secret@127.0.0.1:80",
                "http://127.0.0.1\n:80", "http://127.1:80", "http://0x7f000001:80",
                "http://[::ffff:192.0.2.1]:80"]
        with patch.object(bridge.http.client, "HTTPConnection") as connection:
            for url in urls:
                with self.subTest(url=url):
                    self.write_config(url=url)
                    with self.assertRaises(bridge.BridgeError):
                        self.api.request("GET", "/v1/status")
            connection.assert_not_called()

    def test_invalid_discovery_and_header_injection(self):
        for raw in (b"not-json", b"[]", b"x" * 16385):
            self.path.write_bytes(raw)
            with self.assertRaises(bridge.BridgeError):
                bridge.discovery(self.path)
        self.write_config(token="secret\r\nInjected: true")
        with self.assertRaises(bridge.BridgeError) as failure:
            bridge.discovery(self.path)
        self.assertNotIn("secret", str(failure.exception))
        self.path.unlink()
        with self.assertRaisesRegex(bridge.BridgeError, "enable"):
            bridge.discovery(self.path)

    def test_http_errors_and_redirects_are_not_retried(self):
        for mode, expected in (("error", "HTTP 409"), ("redirect", "HTTP 302"), ("bad-json", "invalid JSON")):
            with self.subTest(mode=mode):
                type(self).mode = mode
                before = len(self.calls)
                with self.assertRaisesRegex(bridge.BridgeError, expected):
                    self.api.request("POST", "/v1/actions", {"op": "home"})
                self.assertEqual(len(self.calls), before + 1)

    def test_http_response_limit(self):
        with patch.object(bridge, "MAX_RESPONSE_BYTES", 4):
            with self.assertRaisesRegex(bridge.BridgeError, "larger"):
                self.api.request("GET", "/v1/status")


if __name__ == "__main__":
    unittest.main()
