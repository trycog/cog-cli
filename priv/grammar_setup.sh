#!/bin/sh

GRAMMAR_ARCHIVE_MAX_BYTES=67108864
GRAMMAR_SETUP_STAGING_NAME=.cog-grammars-staging
GRAMMAR_SETUP_BACKUP_NAME=.cog-grammars-backup
GRAMMAR_SETUP_TRANSACTION_NAME=.cog-grammars-transaction
GRAMMAR_SETUP_COMMITTED_NAME=.cog-grammars-committed

# Tests override this hook to pause after promotion but before the atomic commit
# marker is created.
grammar_setup_before_commit() {
  :
}

grammar_setup_require_owned_path() {
  path=$1
  owner_uid=$("${ID_BIN:-id}" -u) || return 1
  foreign_entry=$("${FIND_BIN:-find}" -H "$path" ! -uid "$owner_uid" -print -quit 2>/dev/null) || {
    printf 'error: unable to validate grammar setup ownership: %s\n' "$path" >&2
    return 1
  }
  if [ -n "$foreign_entry" ]; then
    printf 'error: refusing grammar setup state not owned by uid %s: %s\n' "$owner_uid" "$foreign_entry" >&2
    return 1
  fi
}

grammar_setup_require_owned_tree() {
  tree=$1
  if [ ! -e "$tree" ] && [ ! -L "$tree" ]; then
    return 0
  fi
  if [ ! -d "$tree" ] || [ -L "$tree" ]; then
    printf 'error: refusing non-directory grammar setup state: %s\n' "$tree" >&2
    return 1
  fi
  grammar_setup_require_owned_path "$tree"
}

grammar_setup_prepare_owned_tree() {
  tree=$1
  grammar_setup_require_owned_tree "$tree" || return 1
  if [ -e "$tree" ]; then
    chmod -R u+rwX "$tree" || return 1
  fi
}

grammar_setup_remove_owned_tree() {
  tree=$1
  if [ ! -e "$tree" ] && [ ! -L "$tree" ]; then
    return 0
  fi
  grammar_setup_prepare_owned_tree "$tree" || return 1
  rm -rf "$tree" || return 1
  if [ -e "$tree" ] || [ -L "$tree" ]; then
    printf 'error: unable to remove grammar setup state: %s\n' "$tree" >&2
    return 1
  fi
}

grammar_setup_remove_marker() {
  marker=$1
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 0
  fi
  grammar_setup_require_owned_tree "$marker" || return 1
  rmdir "$marker"
}

grammar_setup_recover_legacy_state() {
  phase_path="$GRAMMAR_SETUP_ROOT/.cog-grammars-phase"
  had_old_path="$GRAMMAR_SETUP_ROOT/.cog-grammars-had-old-tree"
  if [ ! -e "$phase_path" ] && [ ! -L "$phase_path" ] &&
     [ ! -e "$had_old_path" ] && [ ! -L "$had_old_path" ]; then
    return 0
  fi
  if [ -L "$phase_path" ] || { [ -e "$phase_path" ] && [ ! -f "$phase_path" ]; } ||
     [ -L "$had_old_path" ] || { [ -e "$had_old_path" ] && [ ! -f "$had_old_path" ]; }; then
    printf 'error: corrupt legacy grammar setup metadata\n' >&2
    return 1
  fi

  legacy_phase=
  legacy_had_old=
  if [ -f "$phase_path" ]; then
    IFS= read -r legacy_phase < "$phase_path" || true
  fi
  if [ -f "$had_old_path" ]; then
    IFS= read -r legacy_had_old < "$had_old_path" || true
  fi

  case "$legacy_phase:$legacy_had_old" in
    committed:0|committed:1)
      ;;
    promoting:0)
      grammar_setup_remove_owned_tree grammars || return 1
      ;;
    promoting:1)
      printf 'error: corrupt legacy grammar setup state has no backup\n' >&2
      return 1
      ;;
    *)
      printf 'error: corrupt or truncated legacy grammar setup metadata\n' >&2
      return 1
      ;;
  esac
  rm -f "$phase_path" "$had_old_path"
}

grammar_setup_recover_stale() {
  legacy_phase_path="$GRAMMAR_SETUP_ROOT/.cog-grammars-phase"
  legacy_had_old_path="$GRAMMAR_SETUP_ROOT/.cog-grammars-had-old-tree"

  if [ -e "$COMMITTED" ] || [ -L "$COMMITTED" ]; then
    grammar_setup_require_owned_tree "$COMMITTED" || return 1
    grammar_setup_require_owned_tree grammars || return 1
    grammar_setup_remove_owned_tree "$BACKUP" || return 1
    grammar_setup_remove_marker "$TRANSACTION" || return 1
    grammar_setup_remove_marker "$COMMITTED" || return 1
    rm -f "$legacy_phase_path" "$legacy_had_old_path"
  elif [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
    grammar_setup_require_owned_tree "$BACKUP" || return 1
    legacy_committed=0
    if [ -f "$legacy_phase_path" ] && [ ! -L "$legacy_phase_path" ] &&
       [ -f "$legacy_had_old_path" ] && [ ! -L "$legacy_had_old_path" ]; then
      grammar_setup_require_owned_path "$legacy_phase_path" || return 1
      grammar_setup_require_owned_path "$legacy_had_old_path" || return 1
      legacy_phase=
      legacy_had_old=
      IFS= read -r legacy_phase < "$legacy_phase_path" || true
      IFS= read -r legacy_had_old < "$legacy_had_old_path" || true
      if [ "$legacy_phase:$legacy_had_old" = committed:1 ]; then
        legacy_committed=1
      fi
    fi

    if [ "$legacy_committed" = 1 ]; then
      # The old implementation wrote committed before backup deletion. Preserve
      # that completed promotion while safely finishing its cleanup.
      grammar_setup_require_owned_tree grammars || return 1
      grammar_setup_remove_owned_tree "$BACKUP" || return 1
    else
      # Otherwise the backup is authoritative, including when SIGKILL left the
      # legacy phase file empty after truncation.
      grammar_setup_remove_owned_tree grammars || return 1
      mv "$BACKUP" grammars || return 1
    fi
    grammar_setup_remove_marker "$TRANSACTION" || return 1
    rm -f "$legacy_phase_path" "$legacy_had_old_path"
  elif [ -e "$TRANSACTION" ] || [ -L "$TRANSACTION" ]; then
    grammar_setup_require_owned_tree "$TRANSACTION" || return 1
    grammar_setup_remove_owned_tree grammars || return 1
    grammar_setup_remove_marker "$TRANSACTION" || return 1
    rm -f "$legacy_phase_path" "$legacy_had_old_path"
  else
    grammar_setup_recover_legacy_state || return 1
  fi

  grammar_setup_remove_owned_tree "$STAGING" || return 1
  grammar_setup_remove_owned_tree "$WORKDIR" || return 1
}

grammar_setup_cleanup() {
  status=$?
  trap - EXIT INT TERM HUP

  if [ "${GRAMMAR_SETUP_INITIALIZED:-0}" = 1 ]; then
    if [ -e "$COMMITTED" ] || [ -L "$COMMITTED" ] ||
       [ "${GRAMMAR_SETUP_PHASE:-building}" = committed ]; then
      if grammar_setup_remove_owned_tree "$BACKUP"; then
        grammar_setup_remove_marker "$TRANSACTION" || status=1
        # Preserve the committed marker if any preceding cleanup failed; stale
        # recovery must never mistake a partial backup for rollback material.
        if [ "$status" -eq 0 ]; then
          grammar_setup_remove_marker "$COMMITTED" || status=1
        fi
      else
        status=1
      fi
    elif [ "${GRAMMAR_SETUP_PHASE:-building}" = promoting ]; then
      if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
        if grammar_setup_remove_owned_tree grammars; then
          if [ -e "$BACKUP" ] && [ ! -L "$BACKUP" ]; then
            mv "$BACKUP" grammars || status=1
          else
            status=1
          fi
        else
          status=1
        fi
      elif [ -e "$TRANSACTION" ] || [ -L "$TRANSACTION" ]; then
        grammar_setup_remove_owned_tree grammars || status=1
      fi
      grammar_setup_remove_marker "$TRANSACTION" || status=1
      grammar_setup_remove_marker "$COMMITTED" || status=1
    fi
    grammar_setup_remove_owned_tree "$WORKDIR" || status=1
    grammar_setup_remove_owned_tree "$STAGING" || status=1
  fi

  exit "$status"
}

grammar_setup_init() {
  umask 077
  GRAMMAR_SETUP_ROOT=$PWD
  WORKDIR="$GRAMMAR_SETUP_ROOT/.cog-grammars-work"
  STAGING="$GRAMMAR_SETUP_ROOT/$GRAMMAR_SETUP_STAGING_NAME"
  BACKUP="$GRAMMAR_SETUP_ROOT/$GRAMMAR_SETUP_BACKUP_NAME"
  TRANSACTION="$GRAMMAR_SETUP_ROOT/$GRAMMAR_SETUP_TRANSACTION_NAME"
  COMMITTED="$GRAMMAR_SETUP_ROOT/$GRAMMAR_SETUP_COMMITTED_NAME"
  GRAMMAR_SETUP_INITIALIZED=1
  GRAMMAR_SETUP_PHASE=building

  trap grammar_setup_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  # The Zig wrapper holds the project-directory lock before this process starts,
  # so every topology marker found here belongs to a terminated prior owner.
  grammar_setup_recover_stale
  mkdir -m 700 "$WORKDIR" "$STAGING"
}

grammar_setup_fetch_source() {
  repo=$1
  commit=$2
  sha256=$3
  archive=$4
  destination=$5

  "$FETCH_SOURCE" \
    "https://codeload.github.com/$repo/tar.gz/$commit" \
    "$archive" \
    "$GRAMMAR_ARCHIVE_MAX_BYTES" \
    "${CURL_BIN:-curl}"
  "$VERIFY_SOURCE" \
    "$archive" \
    "$sha256" \
    "$GRAMMAR_ARCHIVE_MAX_BYTES" \
    "$destination" \
    "${TAR_BIN:-tar}"
}

grammar_setup_promote() {
  if [ -e grammars ] || [ -L grammars ]; then
    grammar_setup_prepare_owned_tree grammars || return 1
    GRAMMAR_SETUP_HAD_OLD_TREE=1
  else
    GRAMMAR_SETUP_HAD_OLD_TREE=0
  fi
  if [ -e "$BACKUP" ] || [ -L "$BACKUP" ] ||
     [ -e "$TRANSACTION" ] || [ -L "$TRANSACTION" ] ||
     [ -e "$COMMITTED" ] || [ -L "$COMMITTED" ]; then
    printf 'error: stale grammar transaction state remained before promotion\n' >&2
    return 1
  fi

  GRAMMAR_SETUP_PHASE=promoting
  mkdir -m 700 "$TRANSACTION"
  if [ "$GRAMMAR_SETUP_HAD_OLD_TREE" = 1 ]; then
    mv grammars "$BACKUP"
  fi
  mv "$STAGING" grammars

  grammar_setup_before_commit

  # Creating this directory is the atomic commit point. Recovery keeps the new
  # tree whenever it exists, even if backup cleanup was interrupted midway.
  mkdir -m 700 "$COMMITTED"
  GRAMMAR_SETUP_PHASE=committed
  trap '' INT TERM HUP
  grammar_setup_remove_owned_tree "$BACKUP"
  grammar_setup_remove_marker "$TRANSACTION"
  grammar_setup_remove_marker "$COMMITTED"
}

grammar_setup_finish() {
  grammar_setup_remove_owned_tree "$WORKDIR"
}
