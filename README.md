# gke-byo-node

1. config the kubectl pointing to the k8s cluster
1. run the `./generate-worker-args.sh --node ubuntu-1 --version 1.28.0` on your work station (replace `1.28.0` with your desired Kubernetes version)
1. copy the setup-worker.sh to the k8s node `scp setup-worker.sh <user>@<node>:~`
1. execute the  setup-worker.sh  with argument provided by generate-worker-args.sh
   ```
   sudo ./setup-worker.sh --name "ubuntu-1" --api-url ...
   ```
1. Approve the CSR
1. The node should be registered to k8s. See the ndoe in `kubectl get node`