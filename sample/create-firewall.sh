gcloud compute firewall-rules create allow-tcp-10250-kubelet \
    --network=default \
    --action=ALLOW \
    --direction=INGRESS \
    --rules=tcp:10250 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=byo-kubelet-server \
    --description="Allow TCP traffic on port 10250 for Kubelet"