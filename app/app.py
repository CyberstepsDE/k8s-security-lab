"""
Intentionally vulnerable "Cluster Health Dashboard" - a fake internal diagnostics
tool with a classic OS command injection bug in its ping feature. This is the
entry point for the lab: exploiting this is how a student becomes "an attacker
who got command execution inside a Pod."

DO NOT deploy this outside an isolated training cluster.
"""
from flask import Flask, request, render_template_string
import subprocess

app = Flask(__name__)

PAGE = """
<!doctype html>
<title>Cluster Health Dashboard</title>
<h1>Cluster Health Dashboard</h1>
<p>Internal diagnostics tool - ping a host to check connectivity.</p>
<form method="get" action="/ping">
  <input name="host" placeholder="host to ping" value="{{ host }}" size="40">
  <button type="submit">Ping</button>
</form>
<pre>{{ output }}</pre>
"""


@app.route("/")
def index():
    return render_template_string(PAGE, host="", output="")


@app.route("/ping")
def ping():
    host = request.args.get("host", "127.0.0.1")
    # VULNERABLE: user input goes straight into a shell string.
    # A real fix is subprocess.run(["ping", "-c", "1", host], shell=False)
    # with the host value validated first.
    result = subprocess.run(
        f"ping -c 1 -W 2 {host}",
        shell=True,
        capture_output=True,
        text=True,
        timeout=15,
    )
    output = result.stdout + result.stderr
    return render_template_string(PAGE, host=host, output=output)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
