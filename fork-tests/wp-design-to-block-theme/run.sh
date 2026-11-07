#!/usr/bin/env bash
# Regression checks for the fork's wp-design-to-block-theme fixes. Fork-only: upstream has no test suite,
# so this folder stays on the fork's main and out of the fix branches offered upstream.
#
# Each case asserts the script's own output line, not only its exit code, so a crash cannot pass as a FAIL.
#
# Usage: fork-tests/wp-design-to-block-theme/run.sh <dir-with-node_modules/playwright>
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="${SCRIPTS:-$HERE/../../wp-design-to-block-theme/skills/wp-design-to-block-theme/scripts}"
PW_DIR="${1:?give a folder where node_modules/playwright is installed}"
WORK="$(mktemp -d)"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
trap 'kill "$SERVER" 2>/dev/null; rm -rf "$WORK"' EXIT
STATUS=0

check() { # label expected_exit pattern actual_exit output
	if [ "$4" -eq "$2" ] && grep -qE -- "$3" <<<"$5"; then
		echo "ok   $1"
	else
		echo "FAIL $1 (exit $4, wanted $2; pattern '$3')"
		echo "$5" | sed 's/^/     /' | head -20
		STATUS=1
	fi
}
page() { echo "<!doctype html><html><head><meta charset=\"utf-8\"><title>Example</title></head><body style=\"margin:0;font-family:sans-serif\">$1</body></html>"; }
sec() { echo "<section style=\"padding:40px 20px\"><h2>$1</h2><p${2:-}>Example text.</p></section>"; }

mkdir -p "$WORK"/{ok,wide,divs,two,three,site}
page "$(sec Alpha)$(sec Beta)" >"$WORK/ok/page.html"
page "$(sec Alpha)$(sec Beta ' style="width:620px"')" >"$WORK/wide/page.html"
page '<div style="padding:40px 20px"><div>Alpha</div></div><div style="padding:40px 20px"><div>Beta</div></div>' >"$WORK/divs/page.html"
cp "$WORK/ok/page.html" "$WORK/two/page.html"
page "$(sec Alpha)$(sec Beta)$(sec Gamma)" >"$WORK/three/page.html"
page "$(sec Alpha)<script>setInterval(()=>fetch('/beacon?'+Date.now()).catch(()=>{}),300)</script>" >"$WORK/site/busy.html"

cd "$PW_DIR" || exit 2
for v in ok wide divs two three; do
	node "$SCRIPTS/capture.mjs" "$WORK/$v/page.html" --out "$WORK/cap-$v" --breakpoints 390 >/dev/null 2>&1
done
run() { OUT=$("$@" 2>&1); CODE=$?; }

# Screenshot width mismatch (horizontal overflow) fails the pixel check.
run node "$SCRIPTS/compare.mjs" "$WORK/cap-ok" "$WORK/cap-wide"
check "an overflowing page fails on screenshot width" 1 "screenshot widths differ at 390px" "$CODE" "$OUT"
run node "$SCRIPTS/compare.mjs" "$WORK/cap-ok" "$WORK/cap-ok"
check "identical captures still pass" 0 "Verdict: PASS" "$CODE" "$OUT"

# Sections: none to compare is NOT RUN, and an unmatched compared section is named.
run node "$SCRIPTS/compare.mjs" "$WORK/cap-divs" "$WORK/cap-two"
check "a design with no sections reports sections NOT RUN" 1 "sections: NOT RUN" "$CODE" "$OUT"
run node "$SCRIPTS/compare.mjs" "$WORK/cap-two" "$WORK/cap-three"
check "an extra compared section is named" 1 'section "Gamma": no matching design section' "$CODE" "$OUT"

# --wait-until: a page that never goes network-idle is captured with load; the default is unchanged.
(cd "$WORK/site" && exec python3 -m http.server "$PORT" >/dev/null 2>&1) &
SERVER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	curl -sf "http://localhost:$PORT/busy.html" | grep -q beacon && break
	sleep 0.5
done
if ! curl -sf "http://localhost:$PORT/busy.html" | grep -q beacon; then
	echo "FAIL the test server on port $PORT does not serve busy.html"
	exit 1
fi
run node "$SCRIPTS/capture.mjs" "http://localhost:$PORT/busy.html" --out "$WORK/c-busy" --breakpoints 390 --timeout 8000
check "the default wait still times out on a busy page" 1 "Timeout 8000ms exceeded" "$CODE" "$OUT"
run node "$SCRIPTS/capture.mjs" "http://localhost:$PORT/busy.html" --out "$WORK/c-load" --breakpoints 390 --timeout 8000 --wait-until load
check "--wait-until load captures a busy page" 0 "busy.html @ 390px" "$CODE" "$OUT"
run node "$SCRIPTS/capture.mjs" "http://localhost:$PORT/busy.html" --out "$WORK/c-bad" --wait-until sometime
check "an unknown --wait-until value is refused" 1 "--wait-until must be one of" "$CODE" "$OUT"

exit $STATUS
