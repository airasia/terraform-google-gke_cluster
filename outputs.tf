output "usage_IAM_roles" {
  description = "Basic IAM role(s) that are generally necessary for using the resources in this module. See https://cloud.google.com/iam/docs/understanding-roles."
  value = [
    "roles/container.developer",
    "roles/storage.objectViewer",
  ]
}

output "cluster_endpoint" {
  value = google_container_cluster.k8s_cluster.endpoint
}

output "cluster_ca_certificate" {
  value = base64decode(google_container_cluster.k8s_cluster.master_auth.0.cluster_ca_certificate)
}
