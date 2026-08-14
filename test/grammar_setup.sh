#!/bin/sh
set -eu

SETUP_LIB=${1:?usage: grammar_setup.sh SETUP_LIB GRAMMAR_LOCK FETCH_SOURCE VERIFY_SOURCE BUILD_ZIG}
GRAMMAR_LOCK=${2:?usage: grammar_setup.sh SETUP_LIB GRAMMAR_LOCK FETCH_SOURCE VERIFY_SOURCE BUILD_ZIG}
FETCH_SOURCE_EXE=${3:?usage: grammar_setup.sh SETUP_LIB GRAMMAR_LOCK FETCH_SOURCE VERIFY_SOURCE BUILD_ZIG}
VERIFY_SOURCE_EXE=${4:?usage: grammar_setup.sh SETUP_LIB GRAMMAR_LOCK FETCH_SOURCE VERIFY_SOURCE BUILD_ZIG}
BUILD_ZIG=${5:?usage: grammar_setup.sh SETUP_LIB GRAMMAR_LOCK FETCH_SOURCE VERIFY_SOURCE BUILD_ZIG}
for variable in SETUP_LIB GRAMMAR_LOCK FETCH_SOURCE_EXE VERIFY_SOURCE_EXE BUILD_ZIG; do
  eval "value=\${$variable}"
  case "$value" in
    /*) ;;
    *) value="$(cd "$(dirname "$value")" && pwd -P)/$(basename "$value")" ;;
  esac
  eval "$variable=\$value"
done

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cog-grammar-setup-test.XXXXXX")
cleanup_test() {
  status=$?
  trap - EXIT INT TERM HUP
  rm -rf "$TEST_ROOT"
  exit "$status"
}
trap cleanup_test EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() {
  printf 'grammar setup test failed: %s\n' "$1" >&2
  exit 1
}

wait_for_file() {
  path=$1
  attempts=0
  while [ ! -f "$path" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 200 ] || fail "timed out waiting for $path"
    sleep 0.05
  done
}

file_mode() {
  mode=$(stat -f '%Lp' "$1" 2>/dev/null) || mode=$(stat -c '%a' "$1")
  printf '%s\n' "$mode"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum "$1")
    printf '%s\n' "${output%% *}"
  elif command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 "$1")
    printf '%s\n' "${output%% *}"
  else
    output=$(openssl dgst -sha256 "$1")
    printf '%s\n' "${output##* }"
  fi
}

mkdir "$TEST_ROOT/siblings"
(
  cd "$TEST_ROOT/siblings"
  umask 000
  "$GRAMMAR_LOCK" . sh -c '
    set -eu
    umask 000
    . "$1"
    grammar_setup_init
    [ "$(dirname "$STAGING")" = "$PWD" ]
    [ "$(dirname "$BACKUP")" = "$PWD" ]
    case "$(LC_ALL=C ls -ld "$WORKDIR")" in drwx------*) ;; *) exit 96;; esac
    case "$(LC_ALL=C ls -ld "$STAGING")" in drwx------*) ;; *) exit 97;; esac
  ' sh "$SETUP_LIB"
) || fail "staging and work directories are not private siblings of grammars"

mkdir "$TEST_ROOT/concurrent"
ready="$TEST_ROOT/concurrent.ready"
release="$TEST_ROOT/concurrent.release"
(
  cd "$TEST_ROOT/concurrent"
  exec "$GRAMMAR_LOCK" . sh -c '
    : > "$1"
    while [ ! -f "$2" ]; do sleep 0.05; done
  ' sh "$ready" "$release"
) &
holder=$!
wait_for_file "$ready"
if (
  cd "$TEST_ROOT/concurrent"
  "$GRAMMAR_LOCK" . sh -c ':'
) >"$TEST_ROOT/concurrent.output" 2>&1; then
  fail "concurrent setup acquired an active kernel lock"
fi
case "$(LC_ALL=C tr '\n' ' ' < "$TEST_ROOT/concurrent.output")" in
  *"already running"*) ;;
  *) fail "concurrent setup did not report the active lock" ;;
esac
: > "$release"
wait "$holder"
[ ! -e "$TEST_ROOT/concurrent/.cog-grammars-setup.lock" ] || fail "runtime lock artifact was created"

mkdir "$TEST_ROOT/wrapper-signal"
wrapper_ready="$TEST_ROOT/wrapper.ready"
wrapper_mutated="$TEST_ROOT/wrapper.mutated"
wrapper_release="$TEST_ROOT/wrapper.release"
(
  cd "$TEST_ROOT/wrapper-signal"
  exec "$GRAMMAR_LOCK" . sh -c '
    trap '\''\
      : > "$2"; \
      while [ ! -f "$3" ]; do sleep 0.05; done; \
      exit 143\
    '\'' TERM
    : > "$1"
    while :; do sleep 0.05; done
  ' sh "$wrapper_ready" "$wrapper_mutated" "$wrapper_release"
) &
wrapper=$!
wait_for_file "$wrapper_ready"
kill -TERM "$wrapper"
wait_for_file "$wrapper_mutated"
if (
  cd "$TEST_ROOT/wrapper-signal"
  "$GRAMMAR_LOCK" . sh -c ':'
) >"$TEST_ROOT/wrapper-still-held.output" 2>&1; then
  fail "lock wrapper released ownership before its TERM-handling child exited"
fi
: > "$wrapper_release"
set +e
wait "$wrapper"
wrapper_status=$?
set -e
[ "$wrapper_status" -eq 143 ] || fail "lock wrapper signal returned $wrapper_status instead of 143"
if (
  cd "$TEST_ROOT/wrapper-signal"
  "$GRAMMAR_LOCK" . sh -c ':'
) >"$TEST_ROOT/wrapper-reacquire.output" 2>&1; then
  :
else
  fail "lock was not released after the forwarded child terminated"
fi

mkdir "$TEST_ROOT/wrapper-kill"
hard_ready="$TEST_ROOT/hard.ready"
hard_child_file="$TEST_ROOT/hard.child"
(
  cd "$TEST_ROOT/wrapper-kill"
  exec "$GRAMMAR_LOCK" . sh -c '
    trap "exit 0" TERM INT HUP
    printf "%s\n" "$$" > "$2"
    : > "$1"
    while :; do sleep 0.05; done
  ' sh "$hard_ready" "$hard_child_file"
) &
hard_wrapper=$!
wait_for_file "$hard_ready"
hard_child=$(cat "$hard_child_file")
kill -KILL "$hard_wrapper"
set +e
wait "$hard_wrapper"
hard_status=$?
set -e
[ "$hard_status" -eq 137 ] || fail "hard-killed lock wrapper returned $hard_status instead of 137"
if (
  cd "$TEST_ROOT/wrapper-kill"
  "$GRAMMAR_LOCK" . sh -c ':'
) >"$TEST_ROOT/hard-still-held.output" 2>&1; then
  fail "hard-killed wrapper released the lock while its child survived"
fi
kill -TERM "-$hard_child"
attempts=0
while ! (
  cd "$TEST_ROOT/wrapper-kill"
  "$GRAMMAR_LOCK" . sh -c ':'
) >"$TEST_ROOT/hard-reacquire.output" 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 200 ] || fail "inherited lock was not released after the surviving child exited"
  sleep 0.05
done

mkdir -p "$TEST_ROOT/signal/grammars"
printf old > "$TEST_ROOT/signal/grammars/old"
signal_ready="$TEST_ROOT/signal.ready"
SETUP_LIB="$SETUP_LIB" SIGNAL_READY="$signal_ready" sh -c '
  set -eu
  cd "$1"
  . "$SETUP_LIB"
  grammar_setup_init
  printf new > "$STAGING/new"
  grammar_setup_before_commit() {
    : > "$SIGNAL_READY"
    while :; do sleep 0.05; done
  }
  grammar_setup_promote
' sh "$TEST_ROOT/signal" &
promoter=$!
wait_for_file "$signal_ready"
kill -TERM "$promoter"
set +e
wait "$promoter"
promoter_status=$?
set -e
[ "$promoter_status" -eq 143 ] || fail "promotion signal returned $promoter_status instead of 143"
[ -f "$TEST_ROOT/signal/grammars/old" ] || fail "signal did not restore the old grammar tree"
[ ! -e "$TEST_ROOT/signal/grammars/new" ] || fail "signal retained the just-promoted grammar tree"
[ ! -e "$TEST_ROOT/signal/.cog-grammars-backup" ] || fail "signal cleanup left a backup"

mkdir -p "$TEST_ROOT/stale/grammars" "$TEST_ROOT/stale/.cog-grammars-backup"
printf new > "$TEST_ROOT/stale/grammars/new"
printf old > "$TEST_ROOT/stale/.cog-grammars-backup/old"
: > "$TEST_ROOT/stale/.cog-grammars-phase"
printf '1\n' > "$TEST_ROOT/stale/.cog-grammars-had-old-tree"
(
  cd "$TEST_ROOT/stale"
  . "$SETUP_LIB"
  grammar_setup_init
)
[ -f "$TEST_ROOT/stale/grammars/old" ] || fail "truncated phase recovery did not restore the backup"
[ ! -e "$TEST_ROOT/stale/grammars/new" ] || fail "truncated phase recovery retained an uncommitted tree"
[ ! -e "$TEST_ROOT/stale/grammars/grammars" ] || fail "truncated phase recovery nested a live tree into the backup"
[ ! -e "$TEST_ROOT/stale/.cog-grammars-backup" ] || fail "truncated phase recovery left a backup"

mkdir -p "$TEST_ROOT/legacy-committed/grammars" "$TEST_ROOT/legacy-committed/.cog-grammars-backup"
printf new > "$TEST_ROOT/legacy-committed/grammars/new"
printf old > "$TEST_ROOT/legacy-committed/.cog-grammars-backup/old"
printf 'committed\n' > "$TEST_ROOT/legacy-committed/.cog-grammars-phase"
printf '1\n' > "$TEST_ROOT/legacy-committed/.cog-grammars-had-old-tree"
(
  cd "$TEST_ROOT/legacy-committed"
  . "$SETUP_LIB"
  grammar_setup_init
)
[ -f "$TEST_ROOT/legacy-committed/grammars/new" ] || fail "legacy committed recovery rolled back the installed tree"
[ ! -e "$TEST_ROOT/legacy-committed/grammars/old" ] || fail "legacy committed recovery restored the obsolete tree"
[ ! -e "$TEST_ROOT/legacy-committed/.cog-grammars-backup" ] || fail "legacy committed recovery left a backup"

mkdir -p "$TEST_ROOT/cleanup-failure/grammars"
printf old > "$TEST_ROOT/cleanup-failure/grammars/old"
if SETUP_LIB="$SETUP_LIB" sh -c '
  set -eu
  cd "$1"
  . "$SETUP_LIB"
  grammar_setup_init
  printf new > "$STAGING/new"
  grammar_setup_remove_owned_tree() {
    if [ "$1" = "$BACKUP" ]; then return 1; fi
    rm -rf "$1"
  }
  grammar_setup_promote
' sh "$TEST_ROOT/cleanup-failure"; then
  fail "simulated backup cleanup failure unexpectedly succeeded"
fi
[ -f "$TEST_ROOT/cleanup-failure/grammars/new" ] || fail "committed cleanup failure discarded the new tree"
[ -d "$TEST_ROOT/cleanup-failure/.cog-grammars-backup" ] || fail "committed cleanup failure lost rollback state"
[ -d "$TEST_ROOT/cleanup-failure/.cog-grammars-committed" ] || fail "committed cleanup failure removed its recovery marker"
(
  cd "$TEST_ROOT/cleanup-failure"
  . "$SETUP_LIB"
  grammar_setup_init
)
[ -f "$TEST_ROOT/cleanup-failure/grammars/new" ] || fail "committed cleanup recovery rolled back a partial backup"
[ ! -e "$TEST_ROOT/cleanup-failure/.cog-grammars-backup" ] || fail "committed cleanup recovery left the backup"
[ ! -e "$TEST_ROOT/cleanup-failure/.cog-grammars-committed" ] || fail "committed cleanup recovery left its marker"

mkdir -p "$TEST_ROOT/new-tree/grammars"
printf partial > "$TEST_ROOT/new-tree/grammars/partial"
printf '0\n' > "$TEST_ROOT/new-tree/.cog-grammars-had-old-tree"
printf 'promoting\n' > "$TEST_ROOT/new-tree/.cog-grammars-phase"
(
  cd "$TEST_ROOT/new-tree"
  . "$SETUP_LIB"
  grammar_setup_init
)
[ ! -e "$TEST_ROOT/new-tree/grammars" ] || fail "prior first-install recovery retained a partial tree"

mkdir -p "$TEST_ROOT/foreign/grammars"
printf old > "$TEST_ROOT/foreign/grammars/old"
cat > "$TEST_ROOT/foreign-id" <<'EOF'
#!/bin/sh
[ "$1" = "-u" ] || exit 98
printf '424242\n'
EOF
chmod +x "$TEST_ROOT/foreign-id"
if (
  cd "$TEST_ROOT/foreign"
  ID_BIN="$TEST_ROOT/foreign-id"
  export ID_BIN
  . "$SETUP_LIB"
  grammar_setup_init
  printf new > "$STAGING/new"
  grammar_setup_promote
) >"$TEST_ROOT/foreign.output" 2>&1; then
  fail "setup promoted a grammar tree not owned by the current identity"
fi
[ -f "$TEST_ROOT/foreign/grammars/old" ] || fail "ownership rejection moved or deleted the existing grammar tree"
[ ! -e "$TEST_ROOT/foreign/grammars/new" ] || fail "ownership rejection installed the new grammar tree"
[ ! -e "$TEST_ROOT/foreign/.cog-grammars-backup" ] || fail "ownership rejection left an undeletable backup"

mkdir -p "$TEST_ROOT/fetch/payload/archive-root" "$TEST_ROOT/fetch/bin" "$TEST_ROOT/fetch/home"
printf good > "$TEST_ROOT/fetch/payload/archive-root/good"
printf bad > "$TEST_ROOT/fetch/payload/archive-root/bad-never-extracted"
tar -czf "$TEST_ROOT/fetch/source-payload.tar.gz" -C "$TEST_ROOT/fetch/payload" archive-root
source_digest=$(sha256_file "$TEST_ROOT/fetch/source-payload.tar.gz")
cat > "$TEST_ROOT/fetch/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$CURL_ARGS"
cat "$CURL_PAYLOAD"
EOF
chmod +x "$TEST_ROOT/fetch/bin/curl"
cat > "$TEST_ROOT/fetch/home/.curlrc" <<'EOF'
--next
--output curlrc-output
http://example.invalid/not-allowed
EOF
CURL_ARGS="$TEST_ROOT/fetch/curl.args"
CURL_PAYLOAD="$TEST_ROOT/fetch/source-payload.tar.gz"
HOME="$TEST_ROOT/fetch/home"
export CURL_ARGS CURL_PAYLOAD HOME
(
  cd "$TEST_ROOT/fetch"
  umask 000
  "$FETCH_SOURCE_EXE" \
    "https://codeload.github.com/owner/repository/tar.gz/0123456789012345678901234567890123456789" \
    direct.tar.gz 67108864 "$TEST_ROOT/fetch/bin/curl"
)
[ "$(file_mode "$TEST_ROOT/fetch/direct.tar.gz")" = 600 ] || fail "production fetch-source did not create a mode-0600 archive"
rm "$TEST_ROOT/fetch/direct.tar.gz"
mkdir -m 700 "$TEST_ROOT/fetch/work" "$TEST_ROOT/fetch/extracted"
(
  cd "$TEST_ROOT/fetch"
  VERIFY_SOURCE="$VERIFY_SOURCE_EXE"
  FETCH_SOURCE="$FETCH_SOURCE_EXE"
  CURL_BIN="$TEST_ROOT/fetch/bin/curl"
  export VERIFY_SOURCE FETCH_SOURCE CURL_BIN
  . "$SETUP_LIB"
  WORKDIR="$TEST_ROOT/fetch/work"
  grammar_setup_fetch_source \
    "owner/repository" \
    "0123456789012345678901234567890123456789" \
    "$source_digest" \
    "$WORKDIR/source.tar.gz" \
    "$TEST_ROOT/fetch/extracted"
)
[ -f "$TEST_ROOT/fetch/extracted/archive-root/good" ] || fail "production verifier did not extract the verified archive"
[ ! -e "$TEST_ROOT/fetch/work/source.tar.gz" ] || fail "verified archive pathname remained reopenable"
[ ! -e "$TEST_ROOT/fetch/work/source.tar.gz.verified" ] || fail "verification exposed a replaceable renamed archive pathname"
IFS= read -r first_curl_arg < "$CURL_ARGS"
[ "$first_curl_arg" = "--disable" ] || fail "curl --disable was not the first option"
curl_args=$(LC_ALL=C tr '\n' ' ' < "$CURL_ARGS")
for required in "--proto =https" "--proto-redir =https" "--max-redirs 3" "--connect-timeout 15" "--max-time 180" "--max-filesize 67108864"; do
  case "$curl_args" in
    *"$required"*) ;;
    *) fail "production curl invocation omitted $required" ;;
  esac
done
case "$curl_args" in
  *"https://codeload.github.com/owner/repository/tar.gz/0123456789012345678901234567890123456789"*) ;;
  *) fail "production curl invocation did not use the pinned HTTPS codeload URL" ;;
esac

if LC_ALL=C grep 'tar xzf "$ARCHIVE' "$BUILD_ZIG" >/dev/null 2>&1; then
  fail "generated setup still reopens a verified archive pathname with tar"
fi

printf 'grammar setup safety tests passed\n'
