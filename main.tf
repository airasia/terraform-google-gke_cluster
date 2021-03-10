terraform {
  required_version = ">= 0.13.1" # see https://releases.hashicorp.com/terraform/
}

locals {
  cluster_name           = format("%s-%s", var.cluster_name, var.name_suffix)
  cluster_firewall_name  = format("%s-%s", var.firewall_name, var.name_suffix)
  node_network_tags      = [format("gke-%s-np-tf-%s", local.cluster_name, random_string.network_tag_substring.result)]
  oauth_scopes           = ["cloud-platform"] # FULL ACCESS to all GCloud services. Limit them by IAM roles in 'gke_service_account' - see https://cloud.google.com/compute/docs/access/service-accounts#accesscopesiam
  master_private_ip_cidr = "172.16.0.0/28"    # the cluster master's private IP will be assigned from this CIDR - https://cloud.google.com/nat/docs/gke-example#step_2_create_a_private_cluster 
  pre_defined_sa_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/stackdriver.resourceMetadata.writer"
    # see https://cloud.google.com/monitoring/kubernetes-engine/observing#troubleshooting
    # see https://www.terraform.io/docs/providers/google/r/container_cluster.html#service_account-1
  ]
  region = data.google_client_config.google_client.region
  gke_location = (
    var.location_type == "REGIONAL" ? local.region : (
      var.location_type == "ZONAL" ? "${local.region}-${var.locations.0}" : (
        "bad location_type" # will force an error
  )))
  node_locations = (
    var.location_type == "REGIONAL" ? formatlist("${local.region}-%s", var.locations) : (
      var.location_type == "ZONAL" ? formatlist("${local.region}-%s", tolist(setsubtract(var.locations, [var.locations.0]))) : (
        ["bad location_type"] # will force an error
  )))

  # DO NOT rely on google_container_cluster.k8s_cluster.master_version to determine the value of gke_node_version.
  # Otherwise, a RE-RUN of 'terraform apply' will be required for the changes
  # to first be applied on the k8s masters, and then for that change to be detected (and applied) on the k8s nodes.
  gke_node_version = var.gke_master_version

  predefined_node_labels = { TF_used_for = "gke", TF_used_by = google_container_cluster.k8s_cluster.name }

  k8s_secrets = flatten([
    for namespace_obj in var.namespaces : [
      for secret_name, secret_data in namespace_obj.secrets : {
        namespace_name = namespace_obj.name
        secret_name    = secret_name
        secret_data    = secret_data
  }]])

  istio_ports = length(distinct(var.istio_ip_names)) == 0 ? [] : [
    "10250", "443", "15017", # for istio - see https://istio.io/latest/docs/setup/platform-setup/gke/
    "8080", "15000",         # for kiali - see https://kiali.io/documentation/latest/installation-guide/#_google_cloud_private_cluster_requirements
  ]
  fireall_ingress_ports = distinct(concat(var.firewall_ingress_ports, local.istio_ports))
}

resource "random_string" "network_tag_substring" {
  length  = 6
  special = false
  upper   = false
}

resource "google_project_service" "gcr_api" {
  service            = "containerregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "container_api" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "networking_api" {
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute_api" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

module "gke_service_account" {
  source       = "airasia/service_account/google"
  version      = "2.0.0"
  name_suffix  = var.name_suffix
  name         = var.sa_name
  display_name = var.sa_name
  description  = "Its IAM role(s) will specify the access-levels that the GKE node(s) may have"
  roles        = distinct(concat(local.pre_defined_sa_roles, var.sa_roles))
  depends_on   = [google_project_service.container_api]
}

resource "google_container_cluster" "k8s_cluster" {
  # see https://cloud.google.com/nat/docs/gke-example#step_2_create_a_private_cluster
  name                     = local.cluster_name
  description              = var.cluster_description
  location                 = local.gke_location
  node_locations           = local.node_locations
  network                  = var.vpc_network
  subnetwork               = var.vpc_subnetwork
  min_master_version       = var.gke_master_version
  logging_service          = var.cluster_logging_service
  monitoring_service       = var.cluster_monitoring_service
  initial_node_count       = 1    # create just 1 node in the default_node_pool before removing it - see https://www.terraform.io/docs/providers/google/r/container_cluster.html#initial_node_count
  remove_default_node_pool = true # remove the default_node_pool immediately as we will use a custom node_pool - see https://www.terraform.io/docs/providers/google/r/container_cluster.html#remove_default_node_pool
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = ! var.enable_public_endpoint # see https://stackoverflow.com/a/57814380/636762
    master_ipv4_cidr_block  = local.master_private_ip_cidr
  }
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_ip_range_name
    services_secondary_range_name = var.services_ip_range_name
  } # enables VPC-native which is required for private clusters - see https://cloud.google.com/kubernetes-engine/docs/how-to/private-clusters#req_res_lim
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      iterator = authorized_network
      content {
        cidr_block   = authorized_network.value.cidr_block
        display_name = authorized_network.value.display_name
      }
    }
  }
  addons_config {
    http_load_balancing {
      disabled = ! var.enable_addon_http_load_balancing
    }
    horizontal_pod_autoscaling {
      disabled = ! var.enable_addon_horizontal_pod_autoscaling
    }
  }
  depends_on = [google_project_service.container_api]
  timeouts {
    create = var.cluster_timeout
    update = var.cluster_timeout
    delete = var.cluster_timeout
  }
}

resource "google_container_node_pool" "node_pools" {
  for_each           = { for obj in var.node_pools : obj.node_pool_name => obj }
  provider           = google-beta
  name               = each.value.node_pool_name
  location           = local.gke_location
  version            = local.gke_node_version
  cluster            = google_container_cluster.k8s_cluster.name
  initial_node_count = each.value.node_count_initial_per_zone
  node_count         = each.value.node_count_current_per_zone
  max_pods_per_node  = each.value.max_pods_per_node
  autoscaling {
    min_node_count = each.value.node_count_min_per_zone
    max_node_count = each.value.node_count_max_per_zone
  }
  management {
    auto_repair  = true
    auto_upgrade = false
  }
  upgrade_settings {
    max_surge       = each.value.max_surge
    max_unavailable = each.value.max_unavailable
  }
  node_config {
    machine_type    = each.value.machine_type
    disk_type       = each.value.disk_type
    disk_size_gb    = each.value.disk_size_gb
    preemptible     = each.value.preemptible
    labels          = merge(local.predefined_node_labels, each.value.node_labels)
    service_account = module.gke_service_account.email
    oauth_scopes    = local.oauth_scopes
    tags            = local.node_network_tags
  }
  depends_on = [google_project_service.container_api]
  timeouts {
    create = var.node_pool_timeout
    update = var.node_pool_timeout
    delete = var.node_pool_timeout
  }
}

resource "kubernetes_namespace" "namespaces" {
  for_each = { for obj in var.namespaces : obj.name => obj }
  metadata {
    name   = each.value.name
    labels = each.value.labels
  }
  timeouts { delete = var.namespace_timeout }
  depends_on = [google_container_node_pool.node_pools]
}

resource "kubernetes_secret" "secrets" {
  for_each = { for obj in local.k8s_secrets : "${obj.namespace_name}:${obj.secret_name}" => obj }
  metadata {
    namespace = each.value.namespace_name
    name      = each.value.secret_name
  }
  data       = each.value.secret_data
  depends_on = [kubernetes_namespace.namespaces]
}

resource "google_compute_global_address" "static_ingress_ip" {
  for_each   = toset(var.ingress_ip_names)
  name       = format("ingress-%s-%s", each.value, var.name_suffix)
  depends_on = [google_project_service.networking_api, google_project_service.compute_api]
  timeouts {
    create = var.ip_address_timeout
    delete = var.ip_address_timeout
  }
}

resource "google_compute_address" "static_istio_ip" {
  for_each   = toset(var.istio_ip_names)
  name       = format("istio-%s-%s", each.value, var.name_suffix)
  depends_on = [google_project_service.networking_api]
  timeouts {
    create = var.ip_address_timeout
    delete = var.ip_address_timeout
  }
}

resource "google_compute_firewall" "cluster_firewall" {
  count         = length(local.fireall_ingress_ports) > 0 ? 1 : 0
  name          = local.cluster_firewall_name
  network       = var.vpc_network
  source_ranges = [local.master_private_ip_cidr]
  target_tags   = local.node_network_tags
  depends_on    = [google_container_node_pool.node_pools, google_project_service.networking_api]
  allow {
    protocol = "tcp"
    ports    = local.fireall_ingress_ports
  }
}

data "google_client_config" "google_client" {}
