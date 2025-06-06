# gke-byo-node

1. run the `./generate-worker-args.sh ubuntu-1`
1. `scp setup-worker.sh <user>@<node>:~`
1. execute the  setup-worker.sh  with argument provided by generate-worker-args.sh
   ```
   sudo ./setup-worker.sh --name "ubuntu-1" --api-url ...
   ```
1. todo