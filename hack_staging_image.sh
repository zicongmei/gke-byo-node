#!/bin/bash
# Purpose: Automatically detect failing GKE staging images from containerd logs,
# pull them from the public release registry, and tag them locally.

echo "--- GKE BYO Node Image Hacker (Log-based) ---"

# 1. Extract unique staging image names from containerd logs
# We look for strings containing 'gke-release-staging' in the last 2000 lines of logs.
echo "--> Searching containerd logs for failing staging images..."
IMAGES=$(sudo journalctl -u containerd --no-pager -n 2000 | \
         grep -oE '[^ "]*gke-release-staging[^ "]*' | \
         sed 's/\\//g' | sort -u)

if [ -z "$IMAGES" ]; then
    echo "  [!] No staging images found in recent logs."
    echo "      If you just started the node, wait a minute for pull attempts to fail and show up in logs."
    exit 0
fi

# 2. Iterate and fix staging images
for STAGING_IMAGE in $IMAGES; do
    echo "---------------------------------------------------"
    echo "Found staging image: $STAGING_IMAGE"
    
    # Extract the base image name, tag, and digest (everything after the last slash)
    # This handles both tagged images and images with digests.
    IMAGE_SUFFIX=$(echo "$STAGING_IMAGE" | awk -F'/' '{print $NF}')
    
    # Construct the equivalent public release URL
    RELEASE_IMAGE="gcr.io/gke-release/$IMAGE_SUFFIX"
    
    echo "  [+] Pulling equivalent from: $RELEASE_IMAGE"
    if sudo ctr -n k8s.io images pull "$RELEASE_IMAGE"; then
        echo "  [✓] Successfully pulled. Tagging as staging name..."
        sudo ctr -n k8s.io images tag "$RELEASE_IMAGE" "$STAGING_IMAGE"
        echo "  [✓] Done."
    else
        echo "  [X] FAILED to pull from $RELEASE_IMAGE"
        
        # Fallback for core k8s images that live in registry.k8s.io
        K8S_RELEASE="registry.k8s.io/$IMAGE_SUFFIX"
        echo "  [+] Attempting fallback pull from: $K8S_RELEASE"
        if sudo ctr -n k8s.io images pull "$K8S_RELEASE"; then
            sudo ctr -n k8s.io images tag "$K8S_RELEASE" "$STAGING_IMAGE"
            echo "  [✓] Successfully pulled from registry.k8s.io and tagged."
        else
            echo "  [X] Fallback also failed."
        fi
    fi
done

echo "---------------------------------------------------"
echo "Image hacking complete. Containerd should now be able to provide these images to Kubelet."
