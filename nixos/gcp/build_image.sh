#!/bin/bash
set -euo pipefail

# Get the directory of this script
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# GCP Configuration (Change these or set as ENV vars)
PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
IMAGE_NAME=${IMAGE_NAME:-nixos-$(date +%Y%m%d-%H%M)}
GCS_BUCKET=${GCS_BUCKET:-} # Required for image creation

echo "Building NixOS GCP image using Docker..."

# Create a temporary directory for the build
BUILD_DIR=$(mktemp -d)
echo "Using temporary build directory: $BUILD_DIR"

# Ensure cleanup on exit
trap "rm -rf $BUILD_DIR" EXIT

# Copy the configuration to the build directory
cp "$DIR/configuration.nix" "$BUILD_DIR/"

# Find and copy user's public SSH key
SSH_KEY=""
if [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
  SSH_KEY="$HOME/.ssh/id_rsa.pub"
elif [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
  SSH_KEY="$HOME/.ssh/id_ed25519.pub"
fi

if [[ -n "$SSH_KEY" ]]; then
  echo "Found SSH key at $SSH_KEY, copying to build directory"
  cp "$SSH_KEY" "$BUILD_DIR/ssh_key.pub"
else
  echo "WARNING: No public SSH key found in ~/.ssh/id_rsa.pub or ~/.ssh/id_ed25519.pub"
  touch "$BUILD_DIR/ssh_key.pub" # Create empty file to avoid Nix build error
fi

docker run --rm \
  -e "NIX_PATH=nixpkgs=channel:nixos-24.11" \
  -v "$BUILD_DIR:/workspace" \
  -w /workspace \
  nixos/nix \
  sh -c "nix-build '<nixpkgs/nixos>' \
    -j auto \
    --cores 0 \
    --option system-features 'benchmark big-parallel kvm' \
    -A config.system.build.googleComputeImage \
    -I nixos-config=./configuration.nix \
    --out-link ./result && cp -vL ./result/*.tar.gz ./nixos-image.tar.gz"

IMAGE_PATH="$BUILD_DIR/nixos-image.tar.gz"

if [[ -n "$GCS_BUCKET" ]]; then
  echo "Uploading image to GCS: gs://$GCS_BUCKET/$IMAGE_NAME.tar.gz"
  gsutil cp "$IMAGE_PATH" "gs://$GCS_BUCKET/$IMAGE_NAME.tar.gz"

  echo "Creating GCP image: $IMAGE_NAME"
  gcloud compute images create "$IMAGE_NAME" \
    --project="$PROJECT_ID" \
    --source-uri="gs://$GCS_BUCKET/$IMAGE_NAME.tar.gz" \
    --guest-os-features="UEFI_COMPATIBLE"
  
  echo "Image creation complete: $IMAGE_NAME"
else
  echo "GCS_BUCKET not set. Image build complete at: $IMAGE_PATH"
  echo "To create the GCP image manually, upload this file to GCS and run:"
  echo "gcloud compute images create $IMAGE_NAME --source-uri gs://YOUR_BUCKET/$IMAGE_NAME.tar.gz --guest-os-features UEFI_COMPATIBLE"
  # Since user asked to keep it in /tmp, we shouldn't delete it if we haven't uploaded it.
  # Let's override the trap to keep the file if bucket isn't set.
  trap - EXIT
  echo "Temporary directory kept at: $BUILD_DIR"
fi
