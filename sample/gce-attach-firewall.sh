
GCE_NAME=$1

INSTANCE_ZONE=$(gcloud compute instances list --filter="name=${GCE_NAME}" --format="value(zone)")

echo "GCE_NAME=${GCE_NAME}, INSTANCE_ZONE=${INSTANCE_ZONE}"

gcloud compute instances add-tags ${GCE_NAME} \
    --tags=byo-kubelet-server \
    --zone=${INSTANCE_ZONE}