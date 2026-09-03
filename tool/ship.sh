#!/bin/bash
# One entry point for everything that ships iGallery.
#
#   tool/ship.sh                        # server + apk + deploy + start
#   tool/ship.sh apk                    # build the APK only, nothing leaves the Mac
#   tool/ship.sh server deploy start    # rebuild the Linux binary, push it, restart it
#   tool/ship.sh start                  # only restart whatever is already on the server
#
# Stages:
#   server  cross-compile the Rust server for x86_64 linux-musl (static)
#   apk     flutter build apk --release, then commit + push the version bump
#   deploy  rsync the source tree, publish both artifacts to the download page,
#           and drop the binary in $SVR_DIR on the server
#   start   kill the running instance in $SVR_DIR and start the new binary
#
# Stages always run in the canonical order above no matter how they are typed on
# the command line: `ship.sh deploy apk` publishing before the build finished
# would ship the previous APK while looking like a fresh release, and
# `ship.sh start deploy` would restart the OLD binary and then overwrite it.
#
# `set -e` is what makes a combined run safe — the server sees nothing unless
# every requested build succeeded, and deploy runs once at the end rather than
# once per artifact.
#
# Artifacts land in iEnglish's public/ because both projects share one download
# page (it lists every file in that directory, grouped by extension). The
# iGallery- prefix is load-bearing: iEnglish's ship.sh prunes iEnglish-* to the
# newest KEEP, so sharing that prefix would evict real iEnglish builds and hand
# iEnglish users a photo app. Pruning here likewise only matches our own prefix.
#
# Auth is SSH keys (one-time `ssh-copy-id root@<SERVER>`); no password is stored
# in this file.
set -e
cd "$(git rev-parse --show-toplevel)"

SERVER="120.55.41.145"
SSH_USER="root"
REMOTE_DIR="/root/iGallery"                        # source tree
REMOTE_PUB="/root/iEnglish/server/relay/public"    # shared download page
SVR_DIR="/root/igallery-svr"                       # where the server actually runs
PUB_PORT=3400                                      # iEnglish relay, serves /downloads
SVR_PORT=9600                                      # igallery-server's own default
MUSL_TARGET="x86_64-unknown-linux-musl"

# The running copy keeps a STABLE name, unlike the stamped artifact on the
# download page. The name is what `pkill -f` matches and what the data dir sits
# next to, so versioning it would leave one orphaned process and one orphaned
# SQLite db per release.
SVR_BIN="igallery-server"

# Keep the build just made plus one previous, so a bad build can be rolled back
# without hoarding every attempt. Matches iEnglish's retention.
KEEP=2

usage() {
  echo "usage: tool/ship.sh [server] [apk] [deploy] [start]" >&2
  echo "       no stage means all of them, in that order" >&2
  echo >&2
  echo "  server  cross-compile the Rust server for x86_64 linux-musl (static)" >&2
  echo "  apk     flutter build apk --release, commit + push the version bump" >&2
  echo "  deploy  rsync git-tracked files to $SERVER:$REMOTE_DIR, publish both" >&2
  echo "          artifacts to the download page, prune to newest $KEEP," >&2
  echo "          and copy the binary to $SVR_DIR/$SVR_BIN" >&2
  echo "  start   kill the old instance and run $SVR_DIR/$SVR_BIN on :$SVR_PORT" >&2
  echo >&2
  echo "artifacts: iGallery-<stamp>.apk, iGallery-server-<stamp>-linux-x64" >&2
  echo "needs:     musl-cross for server, Android SDK for apk, ssh key for deploy" >&2
  echo "env:       IGALLERY_TOKEN — passed to the server on start; unset = no auth" >&2
}

do_server= do_apk= do_deploy= do_start=
if [ $# -eq 0 ]; then
  do_server=1 do_apk=1 do_deploy=1 do_start=1
else
  for stage in "$@"; do
    case "$stage" in
      server) do_server=1 ;;
      apk)    do_apk=1 ;;
      deploy) do_deploy=1 ;;
      start)  do_start=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "==> ERROR: unknown stage '$stage'" >&2; usage; exit 2 ;;
    esac
  done
fi

# ONE stamp for the whole run: the APK and the server binary of a combined
# release must carry the same version to be provably one source tree.
# YYMMDDHHmm is why plain `sort -r` orders newest first everywhere below.
VERSION=$(date +%y%m%d%H%M)

# Auto-increment the patch version in client/pubspec.yaml: 0.1.0 -> 0.1.1 -> ...
# Only when the APK is actually being built; a server-only or deploy-only run
# must not move the app version.
#
# The `+<code>` half is the build number and it is not decoration: with it missing
# Flutter falls back to the build NAME, which the Android Gradle plugin cannot
# read as an integer and silently replaces with versionCode 1. This file used to
# leave pubspec at a frozen `0.1.0+1`, so every APK ever built claimed to be
# version 1 and no device could tell an upgrade from a reinstall. The macOS
# CFBundleVersion reads the same field.
VERSION_FILES="client/pubspec.yaml client/lib/core/app_info.dart"

bump_version() {
  local current major minor patch next code
  # Drop any existing +build: it is derived from the three numbers below and
  # never carried forward.
  current=$(grep '^version:' client/pubspec.yaml | sed 's/version: *//' | sed 's/+.*//')
  IFS='.' read -r major minor patch <<< "$current"
  patch=$(( ${patch:-0} + 1 ))
  next="${major}.${minor}.${patch}"
  # Two digits each for minor and patch keeps the code readable (0.1.1 -> 101)
  # and monotonic without a second counter that could drift out of step with the
  # name. Android rejects a versionCode above 2100000000; this cannot reach it.
  if [ "${minor:-0}" -gt 99 ] || [ "$patch" -gt 99 ]; then
    echo "==> ERROR: minor/patch must stay below 100 for the versionCode encoding ($next)" >&2
    exit 1
  fi
  code=$(( major * 10000 + minor * 100 + patch ))
  sed -i '' "s/^version:.*/version: ${next}+${code}/" client/pubspec.yaml
  # The About row in the settings sheet is a build-time fact, so it is stamped
  # here rather than read back through a package_info plugin on two platforms.
  sed -i '' "s/^  static const String version = .*/  static const String version = '${next}';/" client/lib/core/app_info.dart
  NEW_VERSION="$next"
  echo "==> Version: ${next} (versionCode ${code}, build ${VERSION})"
}

# Commit the bump right after the artifact that carries it is built.
#
# Leaving it in the working tree is what made every manual `git pull` on the
# server report a conflict: deploy rsyncs the modified pubspec/app_info into
# $REMOTE_DIR, so that checkout is dirty against a commit which does not contain
# the bump, and git refuses to move those files. Committing here means the pushed
# history and the rsynced bytes are the same thing.
#
# Only $VERSION_FILES, never `commit -a`: a release run must not sweep up whatever
# else happens to be in progress in the working tree.
#
# Neither the commit nor the push is fatal. The APK is already built and correct
# at this point, so aborting the run over a missing upstream or an offline network
# would throw away good artifacts; a warning is the honest signal instead.
commit_version() {
  if git diff --quiet HEAD -- $VERSION_FILES; then
    echo "==> Version files already committed, nothing to do"
    return 0
  fi
  git add -- $VERSION_FILES
  if ! git commit -q -m "chore(release): v${NEW_VERSION} (build ${VERSION})"; then
    echo "==> WARNING: git commit failed — the version bump stays uncommitted" >&2
    return 0
  fi
  echo "==> Committed v${NEW_VERSION}"
  if git push; then
    echo "    pushed $(git rev-parse --short HEAD)"
  else
    echo "==> WARNING: git push failed — push by hand, or the server's next pull conflicts again" >&2
  fi
}

APK_NAME="iGallery-${VERSION}.apk"
SRV_NAME="iGallery-server-${VERSION}-linux-x64"
APK_BUILT="client/build/app/outputs/flutter-apk/app-release.apk"
SRV_BUILT="server/target/${MUSL_TARGET}/release/igallery-server"

echo "==> iGallery $VERSION"

if [ -n "$do_server" ]; then
  echo "==> Cross-compiling server ($MUSL_TARGET) ..."
  cd server && cargo build --release --target "$MUSL_TARGET" && cd ..
  echo "    $SRV_NAME ($(du -h "$SRV_BUILT" | cut -f1))"
fi

if [ -n "$do_apk" ]; then
  bump_version
  echo "==> Building release APK ..."
  cd client && flutter build apk --release && cd ..
  echo "    $APK_NAME ($(du -h "$APK_BUILT" | cut -f1))"
  # After the build, so a version that never produced an APK never reaches history.
  commit_version
fi

if [ -n "$do_deploy" ]; then
  # Only tracked files that still exist on disk. A tracked file deleted locally
  # but not yet committed is still listed by `git ls-files`; feeding that to
  # rsync makes it abort with a stat error (exit 23). No --delete: a leftover
  # copy of a removed source file on the server is harmless, and nothing here is
  # compiled remotely.
  echo "==> Syncing git-tracked files to $SERVER:$REMOTE_DIR ..."
  git ls-files -z | while IFS= read -r -d '' f; do
    [ -e "$f" ] && printf '%s\0' "$f"
  done | rsync -az --files-from=- --from0 . "$SSH_USER@$SERVER:$REMOTE_DIR/"

  # Guarded, not unconditional: `ship.sh server deploy start` must not abort on a
  # missing APK just because this checkout has never run the apk stage — that
  # would take the start stage down with it and leave the old server running.
  echo "==> Publishing to $SERVER:$REMOTE_PUB ..."
  if [ -f "$APK_BUILT" ]; then
    rsync -az "$APK_BUILT" "$SSH_USER@$SERVER:$REMOTE_PUB/$APK_NAME"
    echo "    + $APK_NAME"
  fi
  if [ -f "$SRV_BUILT" ]; then
    rsync -az "$SRV_BUILT" "$SSH_USER@$SERVER:$REMOTE_PUB/$SRV_NAME"
    echo "    + $SRV_NAME"

    # The same binary, under its stable name, in the directory it runs from.
    # rsync writes a temp file and renames, so this is safe against the copy the
    # old process is still executing (an in-place write would fail ETXTBSY).
    echo "==> Copying server to $SERVER:$SVR_DIR/$SVR_BIN ..."
    ssh "$SSH_USER@$SERVER" "mkdir -p '$SVR_DIR'"
    rsync -az "$SRV_BUILT" "$SSH_USER@$SERVER:$SVR_DIR/$SVR_BIN"
  fi

  # Prune our own prefixes only. `ls -1d` over a glob matching nothing would
  # error, hence 2>/dev/null; xargs -r keeps an empty list from running rm.
  echo "==> Pruning remote to newest $KEEP per type ..."
  ssh "$SSH_USER@$SERVER" \
    "cd '$REMOTE_PUB' || exit 0
     for pat in 'iGallery-*.apk' 'iGallery-server-*-linux-x64'; do
       ls -1d \$pat 2>/dev/null | sort -r | tail -n +$((KEEP + 1)) | xargs -r rm -f --
     done
     ls -1 iGallery-* 2>/dev/null | sed 's/^/    /'"
fi

if [ -n "$do_start" ]; then
  echo "==> Restarting server on $SERVER:$SVR_DIR ..."

  # The values are prepended to the SCRIPT (over stdin), not passed as env
  # assignments in the ssh command line, and that is not a style choice: a command
  # line reading `SVR_BIN='igallery-server' ... bash -s` puts the pkill pattern
  # inside the cmdline of the login shell running it, so `pkill -f igallery-server`
  # below kills its own session leader — ssh dies mid-restart with exit 144 and the
  # server never comes up. Over stdin the values appear in no cmdline at all.
  #
  # The heredoc stays quoted so the body is read verbatim and `$(pgrep ...)` runs
  # on the server rather than here. printf %q does the quoting for the remote bash.
  #
  # TOKEN rather than IGALLERY_TOKEN on this side: clap reads IGALLERY_TOKEN from
  # the environment, so exporting it empty would be a token of "" — auth enabled
  # with a password nobody can type. The remote script only exports it when set.
  {
    printf 'SVR_DIR=%q SVR_BIN=%q SVR_PORT=%q TOKEN=%q\n' \
      "$SVR_DIR" "$SVR_BIN" "$SVR_PORT" "${IGALLERY_TOKEN:-}"
    cat <<'REMOTE'
set -e
cd "$SVR_DIR" 2>/dev/null || {
  echo "==> ERROR: $SVR_DIR does not exist — run tool/ship.sh server deploy first" >&2
  exit 1
}
[ -f "$SVR_BIN" ] || {
  echo "==> ERROR: $SVR_DIR/$SVR_BIN missing — run tool/ship.sh server deploy first" >&2
  exit 1
}

# Match on the bare name, not "$SVR_DIR/$SVR_BIN": the instance running right now
# may have been started by hand from another directory, and a second server bound
# to the same port would just fail to bind and leave the old code serving.
pkill -f "$SVR_BIN" 2>/dev/null || true
sleep 1

# DATA_DIR is under $SVR_DIR, so the SQLite db, media/ and thumbs/ outlive every
# release — the binary is the only thing a deploy replaces. A first run here
# starts empty; an existing library elsewhere has to be moved in by hand once.
chmod +x "$SVR_BIN"
export DATA_DIR="$SVR_DIR/data"
export PORT="$SVR_PORT"
if [ -n "$TOKEN" ]; then
  export IGALLERY_TOKEN="$TOKEN"
fi
nohup "$SVR_DIR/$SVR_BIN" > "$SVR_DIR/server.log" 2>&1 < /dev/null &

sleep 2
# /v1/auth, not /v1/info: it is the one route the Bearer middleware lets through,
# so it answers 200 whether or not a token is configured. Plain http — the server
# speaks no TLS (the relay on :3400 is the one with the cert).
if curl -s --max-time 5 "http://localhost:$SVR_PORT/v1/auth" | grep -q required; then
  echo "==> Server running (PID: $(pgrep -f "$SVR_BIN" | tr '\n' ' '))"
  echo "    data: $DATA_DIR"
  if [ -n "$TOKEN" ]; then
    echo "    auth: token required"
  else
    echo "    auth: DISABLED — anyone who can reach :$SVR_PORT can read the library"
  fi
else
  echo "==> FAILED:" >&2
  tail -20 "$SVR_DIR/server.log" >&2
  exit 1
fi
REMOTE
  } | ssh -T "$SSH_USER@$SERVER" bash -s
  echo "    http://$SERVER:$SVR_PORT — add this in the app's server list"
fi

# https, not http: the relay serves TLS only, with a self-signed cert (a browser
# shows one warning, Advanced -> Proceed).
echo "==> Done. https://$SERVER:$PUB_PORT/downloads"
