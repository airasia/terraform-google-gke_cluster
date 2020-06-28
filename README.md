Terraform module for a GKE Kubernetes Cluster in GCP

# Version upgrade guide from v1.2.x to v1.3.x

1. While at `v1.2.9`, set `create_auxiliary_node_pool` to `True` - this will create a new additional node pool according to the values of `var.auxiliary_node_pool_config`before proceeding with the breaking change.
   2. Run `terraform apply`
2. Migrate all workloads from existing node pool to the newly created auxiliary node pool
   1. Follow this https://cloud.google.com/kubernetes-engine/docs/tutorials/migrating-node-pool#step_4_migrate_the_workloads
3. Upgrade `gke_cluster` module to `v1.3.0` - this will destroy and recreate the GKE node pool whiile the auxiliary node pool from step 1 will continue to serve requests of GKE cluster
   1. Run `terraform apply`
4. Migrate all workloads back from the auxiliary node pool to the newly created node pool
   1. Follow this https://cloud.google.com/kubernetes-engine/docs/tutorials/migrating-node-pool#step_4_migrate_the_workloads
5. While at `v1.3.0`, set `create_auxiliary_node_pool` to `False` - this will destroy the auxiliary node pool that was created in step 1 as it is no longer needed now
   1. Run `terraform apply`
6. Done
