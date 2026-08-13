#!/bin/sh
set -eu

usage() {
    printf 'usage: %s vMAJOR.MINOR.PATCH [artifact-directory] [release-notes-output]\n' "$0" >&2
    exit 2
}

fail() {
    printf 'release validation failed: %s\n' "$1" >&2
    exit 1
}

[ "$#" -ge 1 ] && [ "$#" -le 3 ] || usage

release_tag=$1
artifact_dir=${2:-}
notes_output=${3:-}
ruby_bin=${RUBY:-ruby}

case "$release_tag" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "release tag must match vMAJOR.MINOR.PATCH (received: $release_tag)" ;;
esac

case "${release_tag#v}" in
    *[!0-9.]*|*.*.*.*|.*|*.|*..*) fail "release tag must match vMAJOR.MINOR.PATCH (received: $release_tag)" ;;
esac

version=${release_tag#v}
source_version=$("$ruby_bin" -ne 'if $_ =~ /^\s*\.version\s*=\s*"([^"]+)"\s*,?\s*$/; puts $1; exit; end' build.zig.zon)
[ -n "$source_version" ] || fail "could not read .version from build.zig.zon"
[ "$release_tag" = "v$source_version" ] || fail "release tag $release_tag does not match build.zig.zon version $source_version"

section_count=$("$ruby_bin" -e '
version = ARGV.fetch(0)
count = File.foreach("CHANGELOG.md").count { |line| line.match?(/^## \[#{Regexp.escape(version)}\](?:\s+-\s+\d{4}-\d{2}-\d{2})?\s*$/) }
puts count
' -- "$version")
[ "$section_count" -eq 1 ] || fail "CHANGELOG.md must contain exactly one section for $version (found $section_count)"

release_notes=$("$ruby_bin" -e '
version = ARGV.fetch(0)
in_section = false
body = []
File.foreach("CHANGELOG.md") do |line|
  if line.match?(/^## \[#{Regexp.escape(version)}\](?:\s+-\s+\d{4}-\d{2}-\d{2})?\s*$/)
    in_section = true
    next
  end
  break if in_section && line.start_with?("## [")
  body << line if in_section
end
print body.join.sub(/\A\s+/, "").sub(/\s+\z/, "")
' -- "$version")
[ -n "$release_notes" ] || fail "CHANGELOG.md section for $version is empty"

if [ -n "$notes_output" ]; then
    notes_dir=$(dirname -- "$notes_output")
    mkdir -p "$notes_dir"
    printf '%s\n' "$release_notes" > "$notes_output"
fi

printf 'Release metadata validated for %s\n' "$release_tag"

if [ -z "$artifact_dir" ]; then
    exit 0
fi

[ -d "$artifact_dir" ] || fail "artifact directory does not exist: $artifact_dir"

expected_names='cog-darwin-arm64.tar.gz
cog-linux-arm64.tar.gz
cog-linux-x86_64.tar.gz'
actual_names=$("$ruby_bin" -e '
dir = ARGV.fetch(0)
puts Dir.children(dir).grep(/\Acog-.*\.tar\.gz\z/).sort
' -- "$artifact_dir")

[ "$actual_names" = "$expected_names" ] || fail "release artifact set does not match expected targets; expected $(printf '%s' "$expected_names" | tr '\n' ' '), found $(printf '%s' "$actual_names" | tr '\n' ' ')"

for artifact_name in $expected_names; do
    artifact="$artifact_dir/$artifact_name"
    tar_entries=$(tar -tzf "$artifact") || fail "could not read release artifact $artifact_name"
    [ "$tar_entries" = cog ] || fail "$artifact_name must contain exactly one top-level cog binary"

    inspect_dir=$(mktemp -d "${TMPDIR:-/tmp}/cog-release-format.XXXXXX")
    tar -xzf "$artifact" -C "$inspect_dir"
    actual_format=$(file -b "$inspect_dir/cog")
    rm -rf "$inspect_dir"

    case "$artifact_name:$actual_format" in
        cog-darwin-arm64.tar.gz:*Mach-O*arm64*) ;;
        cog-linux-arm64.tar.gz:*ELF*ARM\ aarch64*) ;;
        cog-linux-x86_64.tar.gz:*ELF*x86-64*) ;;
        *) fail "$artifact_name has unexpected binary format: $actual_format" ;;
    esac
done

host_os=$(uname -s)
host_arch=$(uname -m)
case "$host_os/$host_arch" in
    Darwin/arm64) host_artifact=cog-darwin-arm64.tar.gz ;;
    Linux/aarch64|Linux/arm64) host_artifact=cog-linux-arm64.tar.gz ;;
    Linux/x86_64) host_artifact=cog-linux-x86_64.tar.gz ;;
    *) fail "unsupported validation host: $host_os/$host_arch" ;;
esac

verify_dir=$(mktemp -d "${TMPDIR:-/tmp}/cog-release-artifact.XXXXXX")
trap 'rm -rf "$verify_dir"' EXIT HUP INT TERM
tar -xzf "$artifact_dir/$host_artifact" -C "$verify_dir"
[ -x "$verify_dir/cog" ] || fail "$host_artifact does not contain an executable cog binary"
artifact_version=$("$verify_dir/cog" --version 2>/dev/null) || fail "$host_artifact cog --version failed"
[ "$artifact_version" = "$source_version" ] || fail "$host_artifact reports version $artifact_version, expected $source_version"

printf 'Release artifacts validated for source version %s\n' "$source_version"
