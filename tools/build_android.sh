#!/usr/bin/env bash
# Single canonical Android build: signed arm64-v8a release APK.
#
#   tools/build_android.sh            -> build/ShardFall.apk
#
# Environment (all optional):
#   GODOT                 Godot 4.7.2 binary (default: godot on PATH)
#   ANDROID_HOME          Android SDK with build-tools + platform-tools (default /opt/android-sdk)
#   JAVA_HOME             JDK 17+ (default: from `javac`)
#   SHARDFALL_KEYSTORE    release keystore path (default ~/.shardfall/release.keystore)
#   SHARDFALL_KEY_ALIAS   key alias (default shardfall)
#   SHARDFALL_KEY_PASS    keystore/key password (default: generated once, stored 0600 next to the keystore)
# The keystore is created on first run and never written into the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/godot"
OUT_DIR="$ROOT/build"
APK="$OUT_DIR/ShardFall.apk"
GODOT="${GODOT:-godot}"
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
EXPECTED_VERSION="4.7.2.stable"

die() { echo "BUILD FAIL: $*" >&2; exit 1; }

# --- Toolchain ---------------------------------------------------------------
command -v "$GODOT" >/dev/null || die "Godot binary '$GODOT' not found"
GV="$("$GODOT" --version | head -n1)"
[[ "$GV" == "$EXPECTED_VERSION"* ]] || die "Godot $EXPECTED_VERSION required, found '$GV'"
TPL="$HOME/.local/share/godot/export_templates/$EXPECTED_VERSION"
[[ -f "$TPL/android_release.apk" ]] || die "Android export templates missing at $TPL"
if [[ -z "${JAVA_HOME:-}" ]]; then
  JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
fi
[[ -x "$JAVA_HOME/bin/keytool" ]] || die "JDK not found (JAVA_HOME=$JAVA_HOME)"
BT="$(ls -d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -n1)"
[[ -n "$BT" && -x "$BT/apksigner" ]] || die "Android build-tools (apksigner) missing under $ANDROID_HOME"
[[ -x "$ANDROID_HOME/platform-tools/adb" ]] || die "Android platform-tools missing under $ANDROID_HOME"
echo "toolchain: Godot $GV | JDK $JAVA_HOME | SDK $ANDROID_HOME | build-tools $(basename "$BT")"

# --- Editor settings: point Godot at the SDK/JDK -----------------------------
ES_DIR="$HOME/.config/godot"
ES="$ES_DIR/editor_settings-4.7.tres"
if [[ ! -f "$ES" ]]; then
  "$GODOT" --headless --editor --quit --path "$PROJECT" >/dev/null 2>&1 || true
fi
[[ -f "$ES" ]] || die "could not create $ES"
python3 - "$ES" "$ANDROID_HOME" "$JAVA_HOME" <<'PY'
import re, sys
path, sdk, jdk = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
for key, val in (("export/android/android_sdk_path", sdk), ("export/android/java_sdk_path", jdk)):
    line = f'{key} = "{val}"'
    if re.search(r"^" + re.escape(key) + r" = .*$", text, re.M):
        text = re.sub(r"^" + re.escape(key) + r" = .*$", line, text, flags=re.M)
    else:
        text = text.rstrip("\n") + "\n" + line + "\n"
open(path, "w", encoding="utf-8").write(text)
PY

# --- Release keystore (outside the repo) --------------------------------------
KS="${SHARDFALL_KEYSTORE:-$HOME/.shardfall/release.keystore}"
ALIAS="${SHARDFALL_KEY_ALIAS:-shardfall}"
PASS_FILE="$(dirname "$KS")/release.pass"
mkdir -p "$(dirname "$KS")"
if [[ -z "${SHARDFALL_KEY_PASS:-}" ]]; then
  if [[ ! -f "$PASS_FILE" ]]; then
    (umask 077; head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24 > "$PASS_FILE")
  fi
  SHARDFALL_KEY_PASS="$(cat "$PASS_FILE")"
fi
if [[ ! -f "$KS" ]]; then
  echo "creating release keystore at $KS"
  "$JAVA_HOME/bin/keytool" -genkeypair -v -keystore "$KS" -alias "$ALIAS" -keyalg RSA -keysize 4096 \
    -validity 10000 -storepass "$SHARDFALL_KEY_PASS" -keypass "$SHARDFALL_KEY_PASS" \
    -dname "CN=Shardfall, OU=Release, O=Shardfall, C=US" >/dev/null 2>&1 || die "keytool failed"
fi
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$KS"
export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$ALIAS"
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$SHARDFALL_KEY_PASS"

# --- Import + export ----------------------------------------------------------
mkdir -p "$OUT_DIR"
rm -f "$APK" "$APK.idsig"
echo "importing assets..."
"$GODOT" --headless --path "$PROJECT" --import > "$OUT_DIR/import.log" 2>&1 || die "import failed (see build/import.log)"
if grep -E "SCRIPT ERROR|Parse Error|Failed loading resource|Error importing" "$OUT_DIR/import.log"; then
  die "errors during import (see build/import.log)"
fi
echo "exporting release APK (preset 'Android')..."
set +e
"$GODOT" --headless --path "$PROJECT" --export-release "Android" "$APK" > "$OUT_DIR/export.log" 2>&1
RC=$?
set -e
if [[ $RC -ne 0 || ! -f "$APK" ]]; then
  cat "$OUT_DIR/export.log"
  die "export failed (rc=$RC)"
fi
if grep -E "SCRIPT ERROR|Parse Error" "$OUT_DIR/export.log"; then
  die "script errors during export (see build/export.log)"
fi

# --- Verify -------------------------------------------------------------------
"$BT/apksigner" verify --verbose "$APK" > "$OUT_DIR/apksigner.log" 2>&1 || { cat "$OUT_DIR/apksigner.log"; die "apksigner verify failed"; }
grep -q "Verified using v2 scheme (APK Signature Scheme v2): true" "$OUT_DIR/apksigner.log" || die "APK is not v2-signed"
python3 - "$APK" <<'PY'
import sys, zipfile
apk = sys.argv[1]
z = zipfile.ZipFile(apk)
names = z.namelist()
abis = sorted({n.split("/")[1] for n in names if n.startswith("lib/") and n.count("/") >= 2})
if abis != ["arm64-v8a"]:
    print(f"BUILD FAIL: native ABIs {abis} (expected only arm64-v8a)"); sys.exit(1)
ctex = [i for i in z.infolist() if i.filename.endswith(".ctex")]
ctex_bytes = sum(i.file_size for i in ctex)
pck = [n for n in names if n.endswith(".pck")]
import os
size = os.path.getsize(apk)
print(f"APK: {apk}")
print(f"APK size: {size / 1048576:.2f} MB ({size} bytes)")
print(f"ABIs: {', '.join(abis)}")
print(f".ctex inside APK: {len(ctex)} files, {ctex_bytes / 1048576:.2f} MB")
if any("web" in n.lower() and n.endswith(".wasm") for n in names):
    print("BUILD FAIL: web artifacts inside APK"); sys.exit(1)
PY
SIG="$(grep -m1 -E 'Signer #1 certificate DN' "$OUT_DIR/apksigner.log" || true)"
"$BT/apksigner" verify --print-certs "$APK" | grep -E "certificate DN|SHA-256 digest" | head -n 2
echo "BUILD OK: signed arm64-v8a release APK"
