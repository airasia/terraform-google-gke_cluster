Terraform module for a GKE Kubernetes Cluster in GCP

# Upgrade guide from v2.4.1 to v2.5.0

1. Upgrade `gke_cluster` module version to `2.5.0`
2. Run `terraform plan`
   1. the plan will show that several resources will be destroyed and recreated under new named indexes
   2. we want to avoid any kind of destruction and/or recreation
3. Move the terraform states
   1. notice that the plan says your **existing** static_ingress_ip resource(s) (let's say `ingressIpX`) will be destroyed and **new** static_ingress_ip resource(s) (let's say `ingressIpY`) will be created
   2. also notice that the plan says your **existing** kubernetes_namespace resource(s) (let's say `namespaceX`) will be destroyed and **new** kubernetes_namespace resource(s) (let's say `namespaceY`) will be created
   3. P.S. if you happen to have multiple static_ingress_ip resource(s) and kubernetes_namespace resource(s), then the plan will show these destructions and recreations **multiple** times. You will need to move the states for EACH of the respective resources one-by-one.
   4. pay attention to the **array indexes**:
      * the `*X` resources (the ones to be **destroyed**) start with array index `[0]` - although it may not show `[0]` in the displayed plan
      * the `*Y` resources (the ones to be **created**) will show array indexes with new named indexes
   5. Use `terraform state mv` to manually move the states of each of `ingressIpX` to `ingressIpY`, and to move the states of each of `namespaceX` to `namespaceY`
      * refer to https://www.terraform.io/docs/commands/state/mv.html to learn more about how to move Terraform state positions
      * once a resource is moved, it will say `Successfully moved 1 object(s).`
      * repeat until all relevant states are moved to their desired positions
4. Run `terraform plan` again
   1. the plan should now show that no changes required
   2. this confirms that you have successfully moved all your resources' states to their new position as required by `v2.5.0`.
5. DONE

---

# Upgrade guide from v2.2.1 to v2.3.0 to 2.4.0

This upgrade process will:
  - drop the use of auxiliary node pools (if any)
  - create a new node pool under terraform's array structure
  - migrate eixsting deployments/workloads from old node pool to new node pool
  - delete old standalone node pool as it's no longer required

Detailed steps provided below:

1. While on `v2.2.1`, remove the variables `create_auxiliary_node_pool` and `auxiliary_node_pool_config`.
   1. run `terraform plan` & `terraform apply`
   2. this will remove any `auxiliary_node_pool` that may have been there
2. Upgrade **gke_cluster** module to `v2.3.0` and set variable `node_pools` with its required params.
   1. value of `node_pool_name` for the new node pool must be different from the name of the old node pool
   2. run `terraform plan` & `terraform apply`
   3. this will create a new node pool as per the specs provided in `node_pools`.
3. Migrate existing deployments/workloads from old node pool to new node pool.
   1. check status of nodes
      1. `kubectl get nodes`
      2. confirm that all nodes from all node pools are shown
      3. confirm that all nodes have status `Ready`
   2. check status of pods
      1. `kubectl get pods -o=wide`
      2. confirm that all pods have status `Running`
      3. confirm that all pods are running on nodes from the old node pool
   3. **cordon** the old node pool
      1. `for node in $(kubectl get nodes -l cloud.google.com/gke-nodepool=<OLD_NODE_POOL_NAME> -o=name); do kubectl cordon "$node"; done` - replace <OLD_NODE_POOL_NAME> with the correct value
      2. check status of nodes
         1. `kubectl get nodes`
         2. confirm that all nodes from the old node pools have status `Ready,SchedulingDisabled`
         2. confirm that all nodes from the new node pools have status `Ready`
      3. check status of pods
         1. `kubectl get pods -o=wide`
         2. confirm that all pods still have status `Running`
         3. confirm that all pods are still running on nodes from the old node pool
   4. initiate **rolling restart** of all deployments
      1. `kubectl rollout restart deployment <DEPLOYMENT_1_NAME> <DEPLOYMENT_2_NAME> <DEPLOYMENT_3_NAME>` - replace <DEPLOYMENT_*_NAME> with correct names of existing deployments
      2. check status of pods
         1. `kubectl get pods -o=wide`
         2. confirm that some pods have status `Running` while some new pods have status `ContainerCreating`
         3. confirm that the new pods with status `ContainerCreating` are running on nodes from the new node pool
         4. repeat status checks until all pods have status `Running` and all pods are running on nodes from the new node pool only
   5. **drain** the old node pool
      1. `for node in $(kubectl get nodes -l cloud.google.com/gke-nodepool=<OLD_NODE_POOL_NAME> -o=name); do kubectl drain --force --ignore-daemonsets --delete-local-data --grace-period=10 "$node"; done` - replace <OLD_NODE_POOL_NAME> with the correct value
      2. confirm that the response says `evicting pod` or `evicted` for all remaining pods in the old node pool
      3. this step may take some time
   6. Migration complete
4. Upgrade **gke_cluster** module to `v2.4.0` and remove use of any obsolete variables.
   1. remove standalone variables such as `machine_type`, `disk_size_gb`, `node_count_initial_per_zone`, `node_count_min_per_zone`, `node_count_max_per_zone`, `node_count_current_per_zone` from the module which are no longer used for standalone node pool.
   2. run `terraform plan` & `terraform apply`
   3. this will remove the old node pool completely
5. DONE

---

# Upgrade guide from v1.2.9 to v1.3.0

1. While at `v1.2.9`, set `create_auxiliary_node_pool` to `True` - this will create a new additional node pool according to the values of `var.auxiliary_node_pool_config` before proceeding with the breaking change.
   * Run `terraform apply`
2. Migrate all workloads from existing node pool to the newly created auxiliary node pool
   * Follow [these instructions](https://cloud.google.com/kubernetes-engine/docs/tutorials/migrating-node-pool#step_4_migrate_the_workloads)
3. Upgrade `gke_cluster` module to `v1.3.0` - this will destroy and recreate the GKE node pool whiile the auxiliary node pool from step 1 will continue to serve requests of GKE cluster
   * Run `terraform apply`
4. Migrate all workloads back from the auxiliary node pool to the newly created node pool
   * Follow [these instructions](https://cloud.google.com/kubernetes-engine/docs/tutorials/migrating-node-pool#step_4_migrate_the_workloads)
5. While at `v1.3.0`, set `create_auxiliary_node_pool` to `False` - this will destroy the auxiliary node pool that was created in step 1 as it is no longer needed now
   * Run `terraform apply`
6. Done
