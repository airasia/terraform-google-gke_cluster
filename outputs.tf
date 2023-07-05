output "usage_IAM_roles" {
  description = "Basic IAM role(s) that are generally necessary for using the resources in this module. See https://cloud.google.com/iam/docs/understanding-roles."
  value = [
    "roles/container.developer",
    "roles/storage.objectViewer",
  ]
}

output "cluster_endpoint" {
  description = "The IP address of the GKE cluster master (a.k.a. the control-plane)."
  value       = google_container_cluster.k8s_cluster.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64 encoded public certificate that is the root of trust for this cluster. Used for connecting to the cluster master via the \"cluster_endpoint\" attribute."
  value       = base64decode(google_container_cluster.k8s_cluster.master_auth.0.cluster_ca_certificate)
}

output "current_master_version" {
  description = "Current version number of the GKE cluster master (a.k.a. the control-plane)."
  value       = google_container_cluster.k8s_cluster.master_version
}

