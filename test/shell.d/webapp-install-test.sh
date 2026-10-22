#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmpdir=$(mktemp -d)
server_pid=""
cleanup() {
  if [[ -n $server_pid ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

home="$tmpdir/home"
mkdir -p "$home/.local/share/applications"

install_webapp() {
  HOME="$home" PATH="$ROOT/bin:$PATH" "$ROOT/bin/omarchy-webapp-install" "$@"
}

desktop_for() {
  printf '%s' "$home/.local/share/applications/$1.desktop"
}

if install_webapp "Example" "https://example.com" "webapp" >"$tmpdir/out" 2>"$tmpdir/err"; then
  :
else
  fail "webapp install accepts an https URL" "$(cat "$tmpdir/err")"
fi

desktop=$(desktop_for Example)
[[ -f $desktop ]] || fail "webapp install writes a desktop file"
grep -Fxq 'Name=Example' "$desktop" || fail "webapp install writes the app name"
grep -Fxq 'Exec=omarchy-launch-webapp "https://example.com"' "$desktop" ||
  fail "webapp install launches the https URL" "$(cat "$desktop")"
pass "webapp install writes an https desktop entry"

grep -Fxq 'StartupWMClass=chrome-example.com__-Default' "$desktop" ||
  fail "webapp install names the window Chromium opens" "$(cat "$desktop")"
pass "webapp install names the window Chromium opens, so titlebars can show the app's name"

for case in \
  "https://web.whatsapp.com/|chrome-web.whatsapp.com__-Default" \
  "https://maps.google.com|chrome-maps.google.com__-Default" \
  "https://discord.com/channels/@me|chrome-discord.com__channels_@me-Default" \
  "https://Example.com:8443/a/b?x=1#y|chrome-example.com__a_b-Default"; do
  [[ $("$ROOT/bin/omarchy-webapp-window-class" "${case%%|*}") == "${case#*|}" ]] ||
    fail "the window class of ${case%%|*} is ${case#*|}" "$("$ROOT/bin/omarchy-webapp-window-class" "${case%%|*}")"
done
pass "web app window classes follow Chromium's host and path naming"

if install_webapp "Plain" "example.org/app" "webapp" >"$tmpdir/out" 2>"$tmpdir/err"; then
  :
else
  fail "webapp install prefixes a schemeless URL with https" "$(cat "$tmpdir/err")"
fi
grep -Fxq 'Exec=omarchy-launch-webapp "https://example.org/app"' "$(desktop_for Plain)" ||
  fail "webapp install stores the prefixed https URL" "$(cat "$(desktop_for Plain)")"
pass "webapp install prefixes a schemeless URL with https"

if install_webapp "Local" "https://localhost:47990" "webapp" "omarchy-launch-webapp https://localhost:47990 --ignore-certificate-errors" >"$tmpdir/out" 2>"$tmpdir/err"; then
  :
else
  fail "webapp install keeps a custom https exec" "$(cat "$tmpdir/err")"
fi
grep -Fxq 'Exec=omarchy-launch-webapp https://localhost:47990 --ignore-certificate-errors' "$(desktop_for Local)" ||
  fail "webapp install writes the custom exec" "$(cat "$(desktop_for Local)")"
grep -Fxq 'StartupWMClass=chrome-localhost__-Default' "$(desktop_for Local)" ||
  fail "a custom exec still names its window after the URL it opens" "$(cat "$(desktop_for Local)")"
pass "webapp install keeps a custom https exec"

for url in "javascript:alert(1)" "file:///etc/passwd" "data:text/html,hi" "ftp://example.com" "ext://x"; do
  if install_webapp "Bad" "$url" "webapp" >"$tmpdir/out" 2>"$tmpdir/err"; then
    fail "webapp install refuses '$url'"
  fi
  grep -Fq 'must be http or https' "$tmpdir/err" ||
    fail "webapp install names the scheme refusal for '$url'" "$(cat "$tmpdir/err")"
  [[ ! -e $(desktop_for Bad) ]] || fail "webapp install does not write a desktop file for '$url'"
done
pass "webapp install refuses non-http(s) URLs"

# Raw whitespace is not valid URL data, and before Exec argument quoting it
# split browser flags or additional URLs into separate arguments.
for url in \
  " javascript:alert(1)" \
  " file:///etc/passwd" \
  "https://example.com data:text/html,hi" \
  "https://example.com/ --user-agent=INJECTION_PROOF_MARKER_12345"; do
  if install_webapp "Sneak" "$url" "webapp" >"$tmpdir/out" 2>"$tmpdir/err"; then
    fail "webapp install refuses whitespace in '$url'" "$(cat "$(desktop_for Sneak)")"
  fi
  grep -Fq 'must not contain whitespace' "$tmpdir/err" ||
    fail "webapp install names the whitespace refusal for '$url'" "$(cat "$tmpdir/err")"
  [[ ! -e $(desktop_for Sneak) ]] || fail "webapp install writes no desktop file for '$url'"
done
pass "webapp install refuses a URL carrying whitespace"

# Schemes are case-insensitive, and HTTPS://example.com installed before the
# scheme test existed.
if install_webapp "Upper" "HTTPS://example.com" "webapp" >"$tmpdir/out" 2>"$tmpdir/err"; then
  :
else
  fail "webapp install accepts an uppercase scheme" "$(cat "$tmpdir/err")"
fi
grep -Fxq 'Exec=omarchy-launch-webapp "HTTPS://example.com"' "$(desktop_for Upper)" ||
  fail "webapp install keeps the uppercase scheme" "$(cat "$(desktop_for Upper)")"
pass "webapp install accepts an uppercase http scheme"

# The interactive prompt fetches the site's icon, so a refused URL must be
# refused before anything dereferences it.
stubs="$tmpdir/stubs"
mkdir -p "$stubs"

cat >"$stubs/gum" <<'GUM'
#!/bin/bash
count=$(cat "$GUM_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" >"$GUM_COUNT"
sed -n "${count}p" "$GUM_ANSWERS"
GUM

cat >"$stubs/curl" <<'CURL'
#!/bin/bash
printf '%s\n' "$*" >>"$CURL_LOG"
exit 1
CURL

chmod +x "$stubs/gum" "$stubs/curl"

printf 'Evil\nfile:///etc/passwd\n' >"$tmpdir/answers"
: >"$tmpdir/gum-count"
: >"$tmpdir/curl-log"

if GUM_ANSWERS="$tmpdir/answers" GUM_COUNT="$tmpdir/gum-count" CURL_LOG="$tmpdir/curl-log" \
  PATH="$stubs:$PATH" HOME="$home" "$ROOT/bin/omarchy-webapp-install" \
  >"$tmpdir/out" 2>"$tmpdir/err"; then
  fail "interactive webapp install refuses a file: URL" "$(cat "$tmpdir/out")"
fi
grep -Fq 'must be http or https' "$tmpdir/err" ||
  fail "interactive webapp install names the scheme refusal" "$(cat "$tmpdir/err")"
[[ ! -s $tmpdir/curl-log ]] ||
  fail "interactive webapp install refuses before fetching the URL" "$(cat "$tmpdir/curl-log")"
[[ ! -e $(desktop_for Evil) ]] || fail "interactive webapp install writes no desktop file"
pass "interactive webapp install refuses a bad URL before fetching it"

cat >"$stubs/curl" <<'CURL'
#!/bin/bash
output=""
url=""
while (( $# > 0 )); do
  case "$1" in
  -o)
    output=$2
    shift 2
    ;;
  http://* | https://*)
    url=$1
    shift
    ;;
  *) shift ;;
  esac
done

printf '%s\n' "$url" >>"$CURL_LOG"
if [[ $url == "https://example.com/app" ]]; then
  printf '%s\n' '<link rel="apple-touch-icon" href="http://127.0.0.1/private-action">'
elif [[ $url == "https://example.com/default-port" ]]; then
  printf '%s\n' '<link rel="apple-touch-icon" href="https://example.com:443/icon.png">'
elif [[ $url == "https://example.com:443/icon.png" ]]; then
  printf 'image' >"$output"
elif [[ $url == "https://User:Secret@example.com/credentialed" ]]; then
  printf '%s\n' '<link rel="apple-touch-icon" href="/credentialed-icon.png">'
elif [[ $url == "https://User:Secret@example.com/credentialed-icon.png" ]]; then
  printf 'image' >"$output"
elif [[ $url == "https://example.com/apple-touch-icon.png" ]]; then
  printf 'image' >"$output"
else
  exit 22
fi
CURL

cat >"$stubs/file" <<'FILE'
#!/bin/bash
printf '%s\n' image/png
FILE

chmod +x "$stubs/curl" "$stubs/file"
: >"$tmpdir/curl-log"

if CURL_LOG="$tmpdir/curl-log" PATH="$stubs:$ROOT/bin:/usr/bin:/bin" HOME="$home" \
  "$ROOT/bin/omarchy-webapp-install" "Steered" "https://example.com/app" "" \
  >"$tmpdir/out" 2>"$tmpdir/err"; then
  :
else
  fail "webapp install falls back to a same-origin icon" "$(cat "$tmpdir/err")"
fi

grep -Fxq 'https://example.com/apple-touch-icon.png' "$tmpdir/curl-log" ||
  fail "webapp install tries the site's same-origin default icon" "$(cat "$tmpdir/curl-log")"
if grep -Fq '127.0.0.1' "$tmpdir/curl-log"; then
  fail "webapp install does not follow a page-provided icon to another origin" "$(cat "$tmpdir/curl-log")"
fi
pass "webapp install keeps automatic icon requests on the selected site's origin"

: >"$tmpdir/curl-log"
if CURL_LOG="$tmpdir/curl-log" PATH="$stubs:$ROOT/bin:/usr/bin:/bin" HOME="$home" \
  "$ROOT/bin/omarchy-webapp-install" "DefaultPort" "https://example.com/default-port" "" \
  >"$tmpdir/out" 2>"$tmpdir/err"; then
  :
else
  fail "webapp install accepts an explicit default port on a same-origin icon" "$(cat "$tmpdir/err")"
fi
grep -Fxq 'https://example.com:443/icon.png' "$tmpdir/curl-log" ||
  fail "webapp install normalizes default ports for origin comparison" "$(cat "$tmpdir/curl-log")"
pass "webapp install treats an explicit default port as the same origin"

: >"$tmpdir/curl-log"
if CURL_LOG="$tmpdir/curl-log" PATH="$stubs:$ROOT/bin:/usr/bin:/bin" HOME="$home" \
  "$ROOT/bin/omarchy-webapp-install" "Credentialed" "https://User:Secret@example.com/credentialed" "" \
  >"$tmpdir/out" 2>"$tmpdir/err"; then
  :
else
  fail "webapp install fetches an icon for a credentialed URL" "$(cat "$tmpdir/err")"
fi
grep -Fxq 'https://User:Secret@example.com/credentialed-icon.png' "$tmpdir/curl-log" ||
  fail "webapp install preserves credentials when constructing relative icon URLs" "$(cat "$tmpdir/curl-log")"
pass "webapp install preserves URL credentials in automatic icon requests"

rm "$stubs/curl"
server_url_file="$tmpdir/server-url"
sink_log="$tmpdir/redirect-sink"

python3 - "$server_url_file" "$sink_log" >/dev/null <<'PY' &
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

url_file, sink_log = sys.argv[1:]

class SinkHandler(BaseHTTPRequestHandler):
  def log_message(self, *args):
    pass

  def do_GET(self):
    with open(sink_log, "a", encoding="utf-8") as log:
      log.write(self.path + "\n")
    self.send_response(200)
    self.end_headers()
    self.wfile.write(b"image")

sink = ThreadingHTTPServer(("127.0.0.1", 0), SinkHandler)
threading.Thread(target=sink.serve_forever, daemon=True).start()

class SiteHandler(BaseHTTPRequestHandler):
  def log_message(self, *args):
    pass

  def do_GET(self):
    if self.path == "/app":
      self.send_response(200)
      self.end_headers()
      self.wfile.write(b'<link rel="apple-touch-icon" href="/redirect-icon.png">')
    elif self.path == "/redirect-icon.png":
      self.send_response(302)
      self.send_header("Location", f"http://127.0.0.1:{sink.server_port}/private-action")
      self.end_headers()
    elif self.path == "/apple-touch-icon.png":
      self.send_response(200)
      self.end_headers()
      self.wfile.write(b"image")
    else:
      self.send_response(404)
      self.end_headers()

site = ThreadingHTTPServer(("127.0.0.1", 0), SiteHandler)
with open(url_file, "w", encoding="utf-8") as output:
  output.write(f"http://127.0.0.1:{site.server_port}")
site.serve_forever()
PY
server_pid=$!

for _ in {1..50}; do
  [[ -s $server_url_file ]] && break
  sleep 0.1
done
[[ -s $server_url_file ]] || fail "local redirect fixture starts"
site_url=$(cat "$server_url_file")

redirect_status=0
PATH="$stubs:$ROOT/bin:/usr/bin:/bin" HOME="$home" \
  "$ROOT/bin/omarchy-webapp-install" "Redirected" "$site_url/app" "" \
  >"$tmpdir/out" 2>"$tmpdir/err" || redirect_status=$?
kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=""

(( redirect_status == 0 )) ||
  fail "webapp install falls back after a discovered icon redirects" "$(cat "$tmpdir/err")"
[[ ! -s $sink_log ]] ||
  fail "webapp install does not follow a discovered icon redirect off-origin" "$(cat "$sink_log")"
pass "webapp install refuses redirects for automatically discovered icons"
