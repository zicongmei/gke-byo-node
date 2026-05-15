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
VM_NAME=nixos-vm-5
ZONE="us-central1-a"
gcloud compute instances create $VM_NAME \
    --image="$IMAGE_NAME" \
    --zone="${ZONE}" \
    --machine-type="e2-medium"
```

### SCP and SSH as root

Since the root user's SSH key is baked into the image, you can connect directly as root.

If the VM has a **public IP** and your firewall (GCP firewall rule) allows port 22, you can use standard SSH:

```bash
PUBLIC_IP=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
echo $PUBLIC_IP

scp ../setup_nix_node.py root@$PUBLIC_IP:~

ssh root@$PUBLIC_IP
```


## Configuration

You can customize the NixOS system by editing `configuration.nix`. This file is the standard NixOS configuration where you can add packages, users, and services.
