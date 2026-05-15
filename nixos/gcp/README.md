# NixOS GCP Image Build

This directory contains scripts to build a NixOS VM image for Google Cloud Platform (GCP) and deploy it.

## Prerequisites

- **Docker**: Used to run the Nix build environment.
- **gcloud SDK**: Used to upload the image and manage GCP resources.

## Build the Image

The `build_image.sh` script handles the entire process:
1. Creates a temporary build environment.
2. Uses Docker to build a NixOS GCP image (`.tar.gz`).
3. (Optional) Uploads the image to a GCS bucket and creates a GCP Compute Image.

### Environment Variables

- `GCS_BUCKET`: (Required for automation) The GCS bucket to upload the image tarball to.
- `IMAGE_NAME`: (Optional) The name for the GCP image. Defaults to `nixos-YYYYMMDD-HHMM`.
- `PROJECT_ID`: (Optional) Your GCP Project ID. Defaults to your current `gcloud` configuration.

### Example Usage

```bash
# 1. Define the image name explicitly
export IMAGE_NAME="nixos-$(date +%Y%m%d-%H%M)"
echo "IMAGE_NAME=$IMAGE_NAME"

# 2. Build and create GCP image automatically
GCS_BUCKET="$USER-nixos-images" IMAGE_NAME=$IMAGE_NAME ./build_image.sh

# Or build only (artifact remains in /tmp)
./build_image.sh
```

## Create a VM from the Image

Once the image is created in GCP, you can launch a VM using the same variable:

```bash
gcloud compute instances create nixos-vm-1 \
    --image="$IMAGE_NAME" \
    --zone="us-central1-a" \
    --machine-type="e2-medium"
```

## Configuration

You can customize the NixOS system by editing `configuration.nix`. This file is the standard NixOS configuration where you can add packages, users, and services.
