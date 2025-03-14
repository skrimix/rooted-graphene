#!/usr/bin/env bash

# Requires git, jq, and curl

KEY_AVB=${KEY_AVB:-avb.key}
KEY_OTA=${KEY_OTA:-ota.key}
CERT_OTA=${CERT_OTA:-ota.crt}
# Or else, set these env vars
KEY_AVB_BASE64=${KEY_AVB_BASE64:-''}
KEY_OTA_BASE64=${KEY_OTA_BASE64:-''}
CERT_OTA_BASE64=${CERT_OTA_BASE64:-''}

# Set these env vars, or else these params will be queries interactively
# PASSPHRASE_AVB
# PASSPHRASE_OTA

# Enable debug output only after sensitive vars have been set, to reduce risk of leak
DEBUG=${DEBUG:-''}
if [[ -n "${DEBUG}" ]]; then set -x; fi

# Mandatory params
DEVICE_ID=${DEVICE_ID:-} # See here for device IDs https://grapheneos.org/releases
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
GITHUB_REPO=${GITHUB_REPO:-''}

# Optional
# If you want an OTA patched with magisk, set the preinit for your device
MAGISK_PREINIT_DEVICE=${MAGISK_PREINIT_DEVICE:-}
# Skip creation of rootless OTA by setting to "true"
SKIP_ROOTLESS=${SKIP_ROOTLESS:-'false'}
# https://grapheneos.org/releases#stable-channel
OTA_VERSION=${OTA_VERSION:-'latest'}

# It's recommended to pin magisk version in combination with AVB_ROOT_VERSION.
# Breaking changes in magisk might need to be adapted in new avbroot version
# Find latest magisk version here: https://github.com/topjohnwu/Magisk/releases, or:
# curl --fail -sL -I -o /dev/null -w '%{url_effective}' https://github.com/topjohnwu/Magisk/releases/latest | sed 's/.*\/tag\///;'
#MAGISK_VERSION=${MAGISK_VERSION:-'v27.0'}
MAGISK_VERSION=${MAGISK_VERSION:-'kitsune-fork'}

SKIP_CLEANUP=${SKIP_CLEANUP:-''}
# Set asset released by this script to latest version, even when OTA_VERSION already exists for this device
FORCE_OTA_SERVER_UPLOAD=${FORCE_OTA_SERVER_UPLOAD:-'false'}

OTA_CHANNEL=${OTA_CHANNEL:-stable} # Alternative: 'alpha'
OTA_BASE_URL="https://releases.grapheneos.org"

AVB_ROOT_VERSION=3.6.0

CUSTOTA_VERSION=4.10

set -o nounset -o pipefail -o errexit

declare -A POTENTIAL_ASSETS

function generateKeys() {
  downloadAvBroot
  # https://github.com/chenxiaolong/avbroot/tree/077a80f4ce7233b0e93d4a1477d09334af0da246#generating-keys
  # Generate the AVB and OTA signing keys.
  .tmp/avbroot key generate-key -o $KEY_AVB
  .tmp/avbroot key generate-key -o $KEY_OTA

  # Convert the public key portion of the AVB signing key to the AVB public key metadata format.
  # This is the format that the bootloader requires when setting the custom root of trust.
  .tmp/avbroot key extract-avb -k $KEY_AVB -o avb_pkmd.bin

  # Generate a self-signed certificate for the OTA signing key. This is used by recovery to verify OTA updates when sideloading.
  .tmp/avbroot key generate-cert -k $KEY_OTA -o $CERT_OTA

  echo Upload these to your CI server, if necessary.
  echo The script takes these values as env or file
  key2base64
}

function key2base64() {
  KEY_AVB_BASE64=$(base64 -w0 "$KEY_AVB") && echo "KEY_AVB_BASE64=$KEY_AVB_BASE64"
  KEY_OTA_BASE64=$(base64 -w0 "$KEY_OTA") && echo "KEY_OTA_BASE64=$KEY_OTA_BASE64"
  CERT_OTA_BASE64=$(base64 -w0 "$CERT_OTA") && echo "CERT_OTA_BASE64=$CERT_OTA_BASE64"
  export KEY_AVB_BASE64 KEY_OTA_BASE64 CERT_OTA_BASE64
}

function createAndReleaseRootedOta() {
  createRootedOta
  releaseOta

  createOtaServerData
  uploadOtaServerData
}

function createRootedOta() {
  [[ "$SKIP_CLEANUP" != 'true' ]] && trap cleanup EXIT ERR

  findLatestVersion
  checkBuildNecessary
  downloadAndroidDependencies
  patchOTAs
}

function cleanup() {
  echo "Cleaning up..."
  rm -rf .tmp
  unset KEY_AVB_BASE64 KEY_OTA_BASE64 CERT_OTA_BASE64
  echo "Cleanup complete."
}

function checkBuildNecessary() {
  if [[ -n "$MAGISK_PREINIT_DEVICE" ]]; then 
    # e.g. oriole-2023121200-magisk-v26.4-4647f74-dirty.zip
    POTENTIAL_ASSETS['magisk']="$DEVICE_ID-$OTA_VERSION-magisk-$MAGISK_VERSION-$(git rev-parse --short HEAD)$(createDirtySuffix).zip"
  else 
    printGreen "MAGISK_PREINIT_DEVICE not set for device, not creating magisk OTA"
  fi
  
  if [[ "$SKIP_ROOTLESS" != 'true' ]]; then
    POTENTIAL_ASSETS['rootless']="$DEVICE_ID-$OTA_VERSION-rootless-$(git rev-parse --short HEAD)$(createDirtySuffix).zip"
  else
    printGreen "SKIP_ROOTLESS set, not creating rootless OTA"
  fi

  RELEASE_ID=''
  local response

  if [[ -z "$GITHUB_REPO" ]]; then echo "Env Var GITHUB_REPO not set, skipping check for existing release" && return; fi

  echo "Potential release: $OTA_VERSION"

  local params=()
  local url="https://api.github.com/repos/${GITHUB_REPO}/releases"

  if [ -n "${GITHUB_TOKEN}" ]; then
    params+=("-H" "Authorization: token ${GITHUB_TOKEN}")
  fi

  params+=("-H" "Accept: application/vnd.github.v3+json")
  response=$(
    curl --fail -sL "${params[@]}" "${url}" |
      jq --arg release_tag "${OTA_VERSION}" '.[] | select(.tag_name == $release_tag) | {id, tag_name, name, published_at, assets}'
  )

  if [[ -n ${response} ]]; then
    RELEASE_ID=$(echo "$response" | jq -r '.id')
    echo "Release ${OTA_VERSION} exists. ID=$RELEASE_ID"
    
    for flavor in "${!POTENTIAL_ASSETS[@]}"; do
      local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
      echo "Checking if asset exists ${POTENTIAL_ASSET_NAME}"
      
      selected_asset=$(echo "$response" | jq -r --arg assetName "${POTENTIAL_ASSET_NAME}" '.assets[] | select(.name == $assetName)')
  
      if [ -n "$selected_asset" ]; then
        printGreen "Asset with name '$POTENTIAL_ASSET_NAME' already released. Not creating it."
        unset "POTENTIAL_ASSETS[$flavor]"
      else
        echo "No asset found with name '$POTENTIAL_ASSET_NAME'."
      fi
    done
    
    if [ "${#POTENTIAL_ASSETS[@]}" -eq 0 ]; then
      printGreen "All potential assets already exist. Exiting"
      exit 0
    fi
  else
    echo "Release ${OTA_VERSION} does not exist."
  fi
}

function checkMandatoryVariable() {
  for var_name in "$@"; do
    local var_value="${!var_name}"

    if [[ -z "$var_value" ]]; then
      printRed "Missing mandatory param $var_name"
      exit 1
    fi
  done
}

function createDirtySuffix() {
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "-dirty"
  else
    echo ""
  fi
}

function downloadAndroidDependencies() {
  checkMandatoryVariable 'MAGISK_VERSION' 'OTA_TARGET'

  mkdir -p .tmp
  if ! ls ".tmp/magisk-$MAGISK_VERSION.apk" >/dev/null 2>&1 && [[ "${POTENTIAL_ASSETS['magisk']+isset}" ]]; then
    #if [[ "$MAGISK_VERSION" == 'kitsune' ]]; then
    #  curl --fail -sLo ".tmp/magisk-$MAGISK_VERSION.apk" "https://huskydg.github.io/magisk-files/app-release.apk"
    if [[ "$MAGISK_VERSION" == 'kitsune-fork' ]]; then
      curl --fail -sLo ".tmp/magisk-$MAGISK_VERSION.apk" "https://github.com/1q23lyc45/KitsuneMagisk/releases/latest/download/app-release.apk"
    elif [[ "$MAGISK_VERSION" == 'canary' ]]; then
      curl --fail -sLo ".tmp/magisk-$MAGISK_VERSION.apk" "$(curl --fail -sL https://raw.githubusercontent.com/topjohnwu/magisk-files/master/canary.json | jq -r .magisk.link)"
    else
      curl --fail -sLo ".tmp/magisk-$MAGISK_VERSION.apk" "https://github.com/topjohnwu/Magisk/releases/download/$MAGISK_VERSION/Magisk-$MAGISK_VERSION.apk"
    fi
  fi

  if ! ls ".tmp/$OTA_TARGET.zip" >/dev/null 2>&1; then
    curl --fail -sLo ".tmp/$OTA_TARGET.zip" "$OTA_URL"
  fi
}

function findLatestVersion() {
  checkMandatoryVariable DEVICE_ID

  if [[ "$MAGISK_VERSION" == 'latest' ]]; then
    MAGISK_VERSION=$(curl --fail -sL -I -o /dev/null -w '%{url_effective}' https://github.com/topjohnwu/Magisk/releases/latest | sed 's/.*\/tag\///;')
  fi
  echo "Magisk version: $MAGISK_VERSION"

  # Search for a new version grapheneos.
  # e.g. https://releases.grapheneos.org/shiba-stable

  if [[ "$OTA_VERSION" == 'latest' ]]; then
    OTA_VERSION=$(curl --fail -sL "$OTA_BASE_URL/$DEVICE_ID-$OTA_CHANNEL" | head -n1 | awk '{print $1;}')
  fi
  GRAPHENE_TYPE=${GRAPHENE_TYPE:-'ota_update'} # Other option: factory
  OTA_TARGET="$DEVICE_ID-$GRAPHENE_TYPE-$OTA_VERSION"
  OTA_URL="$OTA_BASE_URL/$OTA_TARGET.zip"
  # e.g.  shiba-ota_update-2023121200
  echo "OTA target: $OTA_TARGET; OTA URL: $OTA_URL"
}

function downloadAvBroot() {
  mkdir -p .tmp

  if ! ls ".tmp/avbroot" >/dev/null 2>&1; then
    curl --fail -sL "https://github.com/chenxiaolong/avbroot/releases/download/v$AVB_ROOT_VERSION/avbroot-$AVB_ROOT_VERSION-x86_64-unknown-linux-gnu.zip" >.tmp/avb.zip &&
      echo N | unzip .tmp/avb.zip -d .tmp &&
      rm .tmp/avb.zip &&
      chmod +x .tmp/avbroot
  fi
}

function patchOTAs() {

  downloadAvBroot
  base642key

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local targetFile=".tmp/${POTENTIAL_ASSETS[$flavor]}"
    
    if ls "$targetFile" >/dev/null 2>&1; then 
      printGreen "File $targetFile already exists locally, not patching."
    else
      local args=()
      
      args+=("--output" "$targetFile")
      args+=("--input" ".tmp/$OTA_TARGET.zip")
      args+=("--key-avb" "$KEY_AVB")
      args+=("--key-ota" "$KEY_OTA")
      args+=("--cert-ota" "$CERT_OTA")
       if [[ "$flavor" == 'magisk' ]]; then
         args+=("--magisk" ".tmp/magisk-$MAGISK_VERSION.apk")
         args+=("--magisk-preinit-device" "$MAGISK_PREINIT_DEVICE")
       elif [[ "$flavor" == 'rootless' ]]; then
         args+=("--rootless")
       fi
          
      # If env vars not set, passphrases will be queried interactively
      if [ -v PASSPHRASE_AVB ]; then
        args+=("--pass-avb-env-var" "PASSPHRASE_AVB")
      fi
    
      if [ -v PASSPHRASE_OTA ]; then
        args+=("--pass-ota-env-var" "PASSPHRASE_OTA")
      fi
        
      .tmp/avbroot ota patch "${args[@]}"
    fi
  done
}

function base642key() {
  set +x # Don't expose secrets to log
  if [ -n "$KEY_AVB_BASE64" ]; then
    echo "$KEY_AVB_BASE64" | base64 -d >.tmp/$KEY_AVB
    KEY_AVB=.tmp/$KEY_AVB
  fi

  if [ -n "$KEY_OTA_BASE64" ]; then
    echo "$KEY_OTA_BASE64" | base64 -d >.tmp/$KEY_OTA
    KEY_OTA=.tmp/$KEY_OTA
  fi

  if [ -n "$CERT_OTA_BASE64" ]; then
    echo "$CERT_OTA_BASE64" | base64 -d >.tmp/$CERT_OTA
    CERT_OTA=.tmp/$CERT_OTA
  fi

  if [[ -n "${DEBUG}" ]]; then set -x; fi
}

function releaseOta() {
  checkMandatoryVariable 'GITHUB_REPO' 'GITHUB_TOKEN'

  local response
  if [[ -z "$RELEASE_ID" ]]; then
    response=$(curl --fail -X POST -H "Authorization: token $GITHUB_TOKEN" \
      -d "{
              \"tag_name\": \"$OTA_VERSION\",
              \"target_commitish\": \"main\",
              \"name\": \"$OTA_VERSION\",
              \"body\": \"See [Changelog](https://grapheneos.org/releases#$OTA_VERSION).\"
            }" \
      "https://api.github.com/repos/$GITHUB_REPO/releases")
    RELEASE_ID=$(echo "$response" | jq -r '.id')
  fi

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local assetName="${POTENTIAL_ASSETS[$flavor]}"
    uploadFile ".tmp/$assetName" "$assetName" "application/zip"
  done
}

function uploadFile() {
  local sourceFileName="$1"
  local targetFileName="$2"
  local contentType="$3"

  # Note that --data-binary might lead to out of memory
  curl --fail -X POST -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: $contentType" \
    --upload-file "$sourceFileName" \
    "https://uploads.github.com/repos/$GITHUB_REPO/releases/$RELEASE_ID/assets?name=$targetFileName"
}

function createOtaServerData() {
  downloadCusotaTool

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
    local targetFile=".tmp/${POTENTIAL_ASSET_NAME}"
    
    local args=()
  
    args+=("--input" "${targetFile}")
    args+=("--output" "${targetFile}.csig")
    args+=("--key" "$KEY_OTA")
    args+=("--cert" "$CERT_OTA")
  
    # If env vars not set, passphrases will be queried interactively
    if [ -v PASSPHRASE_OTA ]; then
      args+=("--passphrase-env-var" "PASSPHRASE_OTA")
    fi
  
    .tmp/custota-tool gen-csig "${args[@]}"
  
    mkdir -p ".tmp/${flavor}"
    
    local args=()
    args+=("--file" ".tmp/${flavor}/${DEVICE_ID}.json")
    # e.g. https://github.com/schnatterer/rooted-graphene/releases/download/2023121200-v26.4-e54c67f/oriole-ota_update-2023121200.zip
    # Instead of constructing the location we could also parse it from the upload response
    args+=("--location" "https://github.com/$GITHUB_REPO/releases/download/$OTA_VERSION/$POTENTIAL_ASSET_NAME")
  
    .tmp/custota-tool gen-update-info "${args[@]}"
  done
}

function downloadCusotaTool() {
  mkdir -p .tmp
  # TODO verify, avbroot as well
  # https://github.com/chenxiaolong/Custota/releases/download/v3.0/custota-tool-3.0-x86_64-unknown-linux-gnu.zip.sig

  if ! ls ".tmp/custota-tool" >/dev/null 2>&1; then
    curl --fail -sL "https://github.com/chenxiaolong/Custota/releases/download/v$CUSTOTA_VERSION/custota-tool-$CUSTOTA_VERSION-x86_64-unknown-linux-gnu.zip" >.tmp/custota.zip &&
      echo N | unzip .tmp/custota.zip -d .tmp &&
      rm .tmp/custota.zip &&
      chmod +x .tmp/custota-tool
  fi
}

function uploadOtaServerData() {

  # Update OTA server (github pages)
  local current_branch current_commit current_author
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  current_commit=$(git rev-parse --short HEAD)
  current_author=$(git log -1 --format="%an <%ae>")

  git checkout gh-pages
  
  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"

    uploadFile ".tmp/${POTENTIAL_ASSET_NAME}.csig" "$POTENTIAL_ASSET_NAME.csig" "application/octet-stream"
    
    mkdir -p "$flavor"
    # update only, if current $DEVICE_ID.json does not contain $OTA_VERSION
    # We don't want to trigger users to upgrade on new commits from this repo or new magisk versions
    # They can manually upgrade by downloading the OTAs from the releases and "adb sideload" them
    if ! grep -q "$OTA_VERSION" "$flavor/$DEVICE_ID.json" || [[ "$FORCE_OTA_SERVER_UPLOAD" == 'true' ]]; then
      cp ".tmp/$flavor/$DEVICE_ID.json" "$flavor/$DEVICE_ID.json"
      git add "$flavor/$DEVICE_ID.json"
    else
      printGreen "Skipping update of OTA server, because $OTA_VERSION already in $flavor/$DEVICE_ID.json and FORCE_OTA_SERVER_UPLOAD is false."
    fi
  done
  
  if ! git diff-index --quiet HEAD; then
    # Commit and push only when there are changes
    git config user.name "GitHub Actions" && git config user.email "actions@github.com"
    git commit \
        --message "Update device $DEVICE_ID basing on commit $current_commit" \
        --author="$current_author"
  
    git push origin gh-pages
  fi

  # Switch back to the original branch
  git checkout "$current_branch"
}

function printGreen() {
    echo -e "\e[32m$1\e[0m"
}

function printRed() {
    echo -e "\e[31m$1\e[0m"
}
