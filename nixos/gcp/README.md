# NixOS GCP Image Build

This directory contains scripts to build a NixOS VM image for Google Cloud Platform (GCP) and deploy it.

There are two flavors of images you can build:
1. **Basic NixOS VM Image**: A minimal NixOS GCP image using `configuration.nix` and `build_basic_image.sh`.
2. **GKE Node Certified NixOS Image**: A specialized, GKE-compliant, 100% certified NixOS image using `configuration_gke.nix` and `build_gke_node_image.sh` that passes the `gke-image-certification-suite`.

## Prerequisites

- **Docker**: Used to run the Nix build environment.
- **gcloud SDK**: Used to upload the image and manage GCP resources.

## Build the Images

The build scripts handle the entire process:
1. Creates a temporary build environment.
2. Uses Docker to build a NixOS GCP image (`.tar.gz`).
3. (Optional) Uploads the image to a GCS bucket and creates a GCP Compute Image.

### Environment Variables

- `GCS_BUCKET`: (Required for automation) The GCS bucket to upload the image tarball to.
- `IMAGE_NAME`: (Optional) The name for the GCP image. Defaults to `nixos-YYYYMMDD-HHMM` or `nixos-gke-YYYYMMDD-HHMM`.
- `PROJECT_ID`: (Optional) Your GCP Project ID. Defaults to your current `gcloud` configuration.

### Example Usage

#### 1. Building a Basic Image
```bash
# Build and create GCP image automatically
GCS_BUCKET="$USER-nixos-images" ./nixos/gcp/build_basic_image.sh

# Or build only (artifact remains in /tmp)
./nixos/gcp/build_basic_image.sh
```

#### 2. Building a GKE Node Certified Image
```bash
# Build and create GCP image automatically
GCS_BUCKET="$USER-nixos-images" ./nixos/gcp/build_gke_node_image.sh

# Or build only (artifact remains in /tmp)
./nixos/gcp/build_gke_node_image.sh
```

## Create a VM from the Image

Once the image is created in GCP, you can launch a VM using its name:

```bash
VM_NAME="nixos-vm-1"
ZONE="us-central1-a"
gcloud compute instances create $VM_NAME \
    --image="nixos-gke-20260804-1450" \
    --zone="${ZONE}" \
    --machine-type="e2-medium"
```

### SCP and SSH as root

Since the root user's SSH key is baked into the image, you can connect directly as root.

If the VM has a **public IP** and your firewall allows port 22, you can use standard SSH:

```bash
PUBLIC_IP=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
echo $PUBLIC_IP

scp ../setup_nix_node.py root@$PUBLIC_IP:~

ssh root@$PUBLIC_IP
```


## Customizing Configuration

- Customize the basic system by editing `configuration.nix`.
- Customize the GKE-node certified system by editing `configuration_gke.nix`.
