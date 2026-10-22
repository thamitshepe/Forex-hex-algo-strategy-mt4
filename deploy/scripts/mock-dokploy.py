#!/usr/bin/env python3
"""A stand-in for Dokploy's API, so deploy/scripts/dokploy-apply.sh can be tested
without an instance and without network.

It answers the seven endpoints the provisioner uses, with the response shapes the
real ones return (Dokploy's generated OpenAPI documents no response schemas, so
`project.create` returning `{project, environment}` and `project.one` carrying
`environments[].compose[]` were read out of its source).

State is in memory, so a second run against the same process has to take the
"already exists" path - which is the property that makes running the provisioner
on every push safe.

    MOCK_LOG=/tmp/req.jsonl python3 mock-dokploy.py 8787
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = os.environ.get("MOCK_LOG", "/tmp/dokploy-requests.jsonl")
STATE = {"projects": [], "deploys": 0}


def record(entry):
    with open(LOG, "a") as handle:
        handle.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # the caller's output is the interesting one
        pass

    def _send(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        record({"method": "GET", "path": self.path,
                "api_key": self.headers.get("x-api-key")})
        if path == "/api/project.all":
            self._send(STATE["projects"])
        elif path == "/api/project.one":
            project_id = self.path.split("projectId=")[-1]
            for project in STATE["projects"]:
                if project["projectId"] == project_id:
                    self._send(project)
                    return
            self._send({"error": "not found"}, 404)
        else:
            self._send({"error": f"unexpected GET {path}"}, 404)

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:  # a malformed envelope is worth seeing
            body = {"__unparsed__": raw}
        record({"method": "POST", "path": path, "body": body,
                "api_key": self.headers.get("x-api-key")})

        if path == "/api/project.create":
            STATE["projects"].append({
                "projectId": "proj-1", "name": body.get("name"),
                "environments": [{"environmentId": "env-1", "name": "production",
                                  "isDefault": True, "compose": []}]})
            self._send({"project": {"projectId": "proj-1", "name": body.get("name")},
                        "environment": {"environmentId": "env-1",
                                        "name": "production"}})
        elif path == "/api/compose.create":
            compose = {"composeId": "comp-1", "name": body.get("name"),
                       "appName": body.get("appName")}
            STATE["projects"][0]["environments"][0]["compose"].append(compose)
            self._send(compose)
        elif path in ("/api/compose.update", "/api/compose.saveEnvironment"):
            self._send({})
        elif path == "/api/compose.deploy":
            STATE["deploys"] += 1
            self._send({"ok": True})
        else:
            self._send({"error": f"unexpected POST {path}"}, 404)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    if os.path.exists(LOG):
        os.remove(LOG)
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
