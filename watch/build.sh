#!/usr/bin/env bash
# Compiles every face for the Forerunner 965 and, with --publish, uploads the
# .prg files to the hub so the app's "Install to watch" screen lists them.
#
#   watch/build.sh             build into watch/build/
#   watch/build.sh --publish   build, then upload to the hub
#
# Needs: a JDK, the Connect IQ SDK with the fr965 device (SDK Manager), and for
# --publish the hub's WATCH_TOKEN, from the environment or HUB_ENV_FILE
# (defaults to ../Armstrong-Smart-Hub/.env.local next to this repo).
set -euo pipefail

cd "$(dirname "$0")"

DEVICE="${DEVICE:-fr965}"
HUB_URL="${HUB_URL:-https://armstrong-smart-hub.vercel.app}"
HUB_ENV_FILE="${HUB_ENV_FILE:-../../Armstrong-Smart-Hub/.env.local}"
KEY="${GARMIN_DEV_KEY:-$HOME/.garmin/developer_key.der}"

# id | project folder | name shown in the app
FACES=(
  "armstrong-minimal|ArmstrongFace|Armstrong Minimal"
  "armstrong-data|ArmstrongData|Armstrong Data"
)

# The SDK Manager records the active SDK in current-sdk.cfg.
SDK="${CIQ_SDK:-}"
CFG="$HOME/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg"
if [[ -z "$SDK" && -f "$CFG" ]]; then SDK="$(tr -d '\n' < "$CFG")"; fi
MONKEYC="${SDK%/}/bin/monkeyc"
if [[ ! -x "$MONKEYC" ]]; then
  echo "Connect IQ SDK not found. Install the SDK Manager (developer.garmin.com/connect-iq/sdk), download an SDK and the fr965 device, or set CIQ_SDK." >&2
  exit 1
fi
# Homebrew's JDK is keg-only, so it isn't on PATH by default.
for jdk in /opt/homebrew/opt/openjdk@17/bin /opt/homebrew/opt/openjdk/bin; do
  if ! java -version >/dev/null 2>&1 && [[ -x "$jdk/java" ]]; then PATH="$jdk:$PATH"; fi
done
if ! java -version >/dev/null 2>&1; then
  echo "No Java runtime. Install one: brew install openjdk@17" >&2
  exit 1
fi

# Any 4096-bit RSA key works for sideloading; keep it, since the watch ties an installed app to the key that signed it.
if [[ ! -f "$KEY" ]]; then
  echo "Creating a developer key at $KEY"
  mkdir -p "$(dirname "$KEY")"
  openssl genrsa -out "${KEY%.der}.pem" 4096 2>/dev/null
  openssl pkcs8 -topk8 -inform PEM -outform DER -in "${KEY%.der}.pem" -out "$KEY" -nocrypt
  chmod 600 "$KEY" "${KEY%.der}.pem"
fi

mkdir -p build
for face in "${FACES[@]}"; do
  IFS="|" read -r id dir name <<< "$face"
  echo "Building $name"
  "$MONKEYC" -f "$dir/monkey.jungle" -d "$DEVICE" -o "build/$id.prg" -y "$KEY" -r -w
done

if [[ "${1:-}" != "--publish" ]]; then
  echo "Built into watch/build/. Run with --publish to upload to the hub."
  exit 0
fi

TOKEN="${WATCH_TOKEN:-}"
if [[ -z "$TOKEN" && -f "$HUB_ENV_FILE" ]]; then
  TOKEN="$(grep '^WATCH_TOKEN=' "$HUB_ENV_FILE" | tail -1 | cut -d= -f2-)"
fi
if [[ -z "$TOKEN" ]]; then
  echo "No WATCH_TOKEN in the environment or $HUB_ENV_FILE." >&2
  exit 1
fi

for face in "${FACES[@]}"; do
  IFS="|" read -r id dir name <<< "$face"
  echo "Publishing $name"
  curl -sS --fail-with-body -X PUT \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/octet-stream" \
    --data-binary "@build/$id.prg" \
    "$HUB_URL/api/watch/faces/$id?name=$(printf %s "$name" | sed 's/ /%20/g')"
  echo
done
