#!/bin/bash
# One entry point for everything that ships iGallery.
#
#   tool/ship.sh                  # server + apk + deploy
#   tool/ship.sh apk              # build the APK only, nothing leaves the Mac
#   tool/ship.sh server deploy    # rebuild the Linux binary and push it
#
# Stages always run in the canonical order below no matter how they are typed on
# the command line: `ship.sh deploy apk` publishing before the build finished
# would ship the previous APK while looking like a fresh release.
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
PORT=3400
MUSL_TARGET="x86_64-unknown-linux-musl"

# Keep the build just made plus one previous, so a bad build can be rolled back
# without hoarding every attempt. Matches iEnglish's retention.
KEEP=2

usage() {
  echo "usage: tool/ship.sh [server] [apk] [deploy]" >&2
  echo "       no stage means all of them, in that order" >&2
  echo >&2
  echo "  server  cross-compile the Rust server for x86_64 linux-musl (static)" >&2
  echo "  apk     flutter build apk --release" >&2
  echo "  deploy  rsync git-tracked files to $SERVER:$REMOTE_DIR, publish both" >&2
  echo "          artifacts to the download page, prune to newest $KEEP" >&2
  echo >&2
  echo "artifacts: iGallery-<stamp>.apk, iGallery-server-<stamp>-linux-x64" >&2
  echo "needs:     musl-cross for server, Android SDK for apk, ssh key for deploy" >&2
}

do_server= do_apk= do_deploy=
if [ $# -eq 0 ]; then
  do_server=1 do_apk=1 do_deploy=1
else
  for stage in "$@"; do
    case "$stage" in
      server) do_server=1 ;;
      apk)    do_apk=1 ;;
      deploy) do_deploy=1 ;;
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
  echo "==> Version: ${next} (versionCode ${code}, build ${VERSION})"
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

  echo "==> Publishing to $SERVER:$REMOTE_PUB ..."
  rsync -az "$APK_BUILT" "$SSH_USER@$SERVER:$REMOTE_PUB/$APK_NAME"
  rsync -az "$SRV_BUILT" "$SSH_USER@$SERVER:$REMOTE_PUB/$SRV_NAME"

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

# https, not http: the relay serves TLS only, with a self-signed cert (a browser
# shows one warning, Advanced -> Proceed).
echo "==> Done. https://$SERVER:$PORT/downloads"
