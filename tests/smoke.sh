#!/usr/bin/env bash
# Black-box smoke test: starts PHP's built-in server and checks access control.
#
# Non-destructive on purpose. On a machine where /media/RACHEL/rachel/modules
# exists the app resolves to the real modules/ and admin.sqlite whatever the
# working directory is, so this only makes read calls, and the "delete" probe
# uses a module name that does not exist.
#
# Usage: tests/smoke.sh            (admin password defaults to Rachel+1)
#        RACHEL_TEST_PASS=secret tests/smoke.sh

cd "$(dirname "$0")/.." || exit 1

PORT=${PORT:-8099}
BASE="http://127.0.0.1:$PORT"
PASS=${RACHEL_TEST_PASS:-Rachel+1}
JAR=$(mktemp)
BODY=$(mktemp)
pass=0
fail=0

php -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -f "$JAR" "$BODY"' EXIT
for _ in $(seq 1 50); do
    curl -s -o /dev/null "$BASE/about.html" && break
    sleep 0.1
done

# status <curl args...>  -> prints the HTTP status, leaves the body in $BODY
status() { curl -s -o "$BODY" -w '%{http_code}' "$@"; }

check() { # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); echo "  ok    $1"
    else
        fail=$((fail + 1)); echo "  FAIL  $1 (expected $2, got $3)"
    fi
}

body_has() { grep -q "$1" "$BODY" && echo yes || echo no; }

echo "Anonymous visitor"
check "homepage is public"                 200 "$(status "$BASE/index.php")"
check "quiz page is public"                200 "$(status "$BASE/quiz.php")"
check "quiz list is public"                200 "$(status "$BASE/admin/background.php?getQuizzes=1")"
check "admin page shows the login form"    yes "$(status "$BASE/admin/storage.php" >/dev/null; body_has 'name="pass"')"
check "module list needs login"            401 "$(status "$BASE/admin/background.php?getLocalModuleList=1")"
check "task list needs login"              401 "$(status "$BASE/admin/background.php?getTasks=1")"
check "delete needs login"                 401 "$(status "$BASE/admin/background.php?deleteModule=no-such-module")"
check "stats need login"                   401 "$(status "$BASE/admin/background.php?getStats=1")"
check "quiz grading needs login"           401 "$(status -X POST -d '{}' "$BASE/admin/background.php?gradeSubmission=1")"
check "submission list needs login"        401 "$(status "$BASE/admin/background.php?getQuizSubmissions=1")"

echo "Old fixed cookie value"
check "is no longer accepted"              yes "$(status -b 'rachel-auth=admin' "$BASE/admin/storage.php" >/dev/null; body_has 'name="pass"')"
check "no longer opens background calls"   401 "$(status -b 'rachel-auth=admin' "$BASE/admin/background.php?getLocalModuleList=1")"

echo "Wrong password"
check "does not log in"                    yes "$(status -c "$JAR" -d 'user=admin&pass=definitely-wrong' "$BASE/admin/storage.php" >/dev/null; body_has 'name="pass"')"

echo "Admin session"
status -c "$JAR" -b "$JAR" -L --data-urlencode "user=admin" --data-urlencode "pass=$PASS" "$BASE/admin/storage.php" >/dev/null
check "login opens Content Management"    yes "$(status -c "$JAR" -b "$JAR" "$BASE/admin/storage.php" >/dev/null; body_has 'tab-upload')"
check "module list works when logged in"   200 "$(status -b "$JAR" "$BASE/admin/background.php?getLocalModuleList=1")"
check "quiz list still works when logged in" 200 "$(status -b "$JAR" "$BASE/admin/background.php?getQuizzes=1")"

echo "Logout"
status -c "$JAR" -b "$JAR" "$BASE/admin/logout.php" >/dev/null
check "ends the session"                   401 "$(status -b "$JAR" "$BASE/admin/background.php?getLocalModuleList=1")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
