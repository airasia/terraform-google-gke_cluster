Terraform module for a GKE Kubernetes Cluster in GCP

# Using Helm Charts to install Ingress Nginx

If you want to utilize this feature make sure to declare a `helm` provider in your terraform configuration as follows.

```terraform
provider "helm" {
  version = "2.1.2" # see https://github.com/terraform-providers/terraform-provider-helm/releases
  kubernetes {
    host                   = module.gke_cluster.cluster_endpoint
    token                  = data.google_client_config.google_client.access_token
    cluster_ca_certificate = module.gke_cluster.cluster_ca_certificate
  }
}
```

Pay attention to the `gke_cluster` module output variables used here.

# Upgrade guide from v2.15.0 to v2.16.0

Drop the use of attributes such as `node_count_initial_per_zone` and/or `node_count_current_per_zone` (if any) from the list of objects in `var.node_pools`.

# Upgrade guide from v2.7.1 to v2.8.1

While performing this upgrade, if you are using the `namespace` variable, you may run into one or more of the following errors:

- namespaces is forbidden
- User "system:serviceaccount:devops:default" cannot create resource "namespaces" in API group ""
- User "system:serviceaccount:devops:default" cannot get resource "namespaces" in API group ""
- Get "http://localhost/api/v1/namespaces/<namespace_name>": dial tcp 127.0.0.1:80: connect: connection refused

In order to fix this, you need to declare a `kubernetes` provider in your terraform configuration like the following.

```terraform
provider "kubernetes" {
  version                = "1.13.3" # see https://github.com/terraform-providers/terraform-provider-kubernetes/releases
  load_config_file       = false
  host                   = module.gke_cluster.cluster_endpoint
  token                  = data.google_client_config.google_client.access_token
  cluster_ca_certificate = module.gke_cluster.cluster_ca_certificate
}

data "google_client_config" "google_client" {}
```

Pay attention to the `gke_cluster` module output variables used here.

# Upgrade guide from v2.6.1 to v2.7.1

This upgrade performs 2 changes:
  - Move the declaration of kubernetes secrets into the declaration of kubernetes namesapces
    - see the Pull Request description at https://github.com/airasia/terraform-google-gke_cluster/pull/7
  - Ability to create multiple ingress IPs for istio
    - read below

Detailed steps provided below:

1. Upgrade `gke_cluster` module version to `2.7.1`
2. Run `terraform plan` - DO NOT APPLY this plan
   1. the plan may show that some `istio` resource(s) (if used any) will be destroyed
   2. we want to avoid any kind of destruction and/or recreation
   3. *P.S. to resolve any changes proposed for `kubernetes_secret` resource(s), please refer to [this Pull Request description](https://github.com/airasia/terraform-google-gke_cluster/pull/7) instead*
3. Set the `istio_ip_names` variable with at least one item as `["ip"]`
   1. this is so that the istio IP resource name is backward-compaitble
4. Run `terraform plan` - DO NOT APPLY this plan
   1. now, the plan may show that a `static_istio_ip` resource (if used any) will be destroyed and recreated under new named index
   2. we want to avoid any kind of destruction and/or recreation
   3. *P.S. to resolve any changes proposed for `kubernetes_secret` resource(s), please refer to [this Pull Request description](https://github.com/airasia/terraform-google-gke_cluster/pull/7) instead*
4. Move the terraform states
   1. notice that the plan says your **existing** static_istio_ip resource (let's say `istioIpX`) will be destroyed and **new** static_istio_ip resource (let's say `istioIpY`) will be created
   2. pay attention to the **array indexes**:
      * the `*X` resources (the ones to be **destroyed**) start with array index `[0]` - although it may not show `[0]` in the displayed plan
      * the `*Y` resources (the ones to be **created**) will show array index with new named index
   3. Use `terraform state mv` to manually move the state of `istioIpX` to `istioIpY`
      * refer to https://www.terraform.io/docs/commands/state/mv.html to learn more about how to move Terraform state positions
      * once a resource is moved, it will say `Successfully moved 1 object(s).`
   4. The purpose of this channge is detailed in [this wiki](https://github.com/airasia/terraform-google-external_access/wiki/The-problem-of-%22shifting-all-items%22-in-an-array).
5. Run `terraform plan` again
   1. the plan should now show that no changes required
   2. this confirms that you have successfully moved all your resources' states to their new position as required by `v2.7.1`.
6. DONE

---

# Upgrade guide from v2.4.2 to v2.5.1

This upgrade will move the terraform states of arrays of ingress IPs and k8s namespaces from numbered indexes to named indexes. The purpose of this channge is detailed in [this wiki](https://github.com/airasia/terraform-google-external_access/wiki/The-problem-of-%22shifting-all-items%22-in-an-array).

1. Upgrade `gke_cluster` module version to `2.5.1`
2. Run `terraform plan` - DO NOT APPLY this plan
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
   2. this confirms that you have successfully moved all your resources' states to their new position as required by `v2.5.1`.
5. DONE

---

# Upgrade guide from v2.2.2 to v2.3.1 to 2.4.2

This upgrade process will:
  - drop the use of auxiliary node pools (if any)
  - create a new node pool under terraform's array structure
  - migrate eixsting deployments/workloads from old node pool to new node pool
  - delete old standalone node pool as it's no longer required

Detailed steps provided below:

1. While on `v2.2.2`, remove the variables `create_auxiliary_node_pool` and `auxiliary_node_pool_config`.
   1. run `terraform plan` & `terraform apply`
   2. this will remove any `auxiliary_node_pool` that may have been there
2. Upgrade **gke_cluster** module to `v2.3.1` and set variable `node_pools` with its required params.
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
4. Upgrade **gke_cluster** module to `v2.4.2` and remove use of any obsolete variables.
   1. remove standalone variables such as `machine_type`, `disk_size_gb`, `node_count_initial_per_zone`, `node_count_min_per_zone`, `node_count_max_per_zone`, `node_count_current_per_zone` from the module which are no longer used for standalone node pool.
   2. run `terraform plan` & `terraform apply`
   3. this will remove the old node pool completely
5. DONE

---

# Upgrade guide from v1.2.9 to v1.3.0

This upgrade assigns network tags to the node pool nodes. The upgrade process will:
  - Create an auxiliary node pool.
  - Move all workloads from the existing node pool to the auxiliary node pool
  - Assign network tags to the existing node pool (which causes destruction and recreation of that node pool)
  - Move all workloads back from the auxiliary node pool into the new node pool (which now has network tags)
  - Then delete auxiliary node pool.

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
