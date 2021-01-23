terraform {
  required_version = ">= 0.12.24" # see https://releases.hashicorp.com/terraform/
  experiments      = [variable_validation]
}

provider "google" {
  version = ">= 3.13.0" # see https://github.com/terraform-providers/terraform-provider-google/releases
}

provider "google-beta" {
  version = ">= 3.13.0" # see https://github.com/terraform-providers/terraform-provider-google-beta/releases
}

provider "kubernetes" {
  version                = "1.11.3" # see https://github.com/terraform-providers/terraform-provider-kubernetes/releases
  load_config_file       = false
  host                   = google_container_cluster.k8s_cluster.endpoint
  token                  = data.google_client_config.google_client.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.k8s_cluster.master_auth.0.cluster_ca_certificate)
}

locals {
  cluster_name                = format("%s-%s", var.cluster_name, var.name_suffix)
  ingress_ip_name             = format("%s-%s", var.ingress_ip_name, var.name_suffix)
  istio_ip_name               = format("%s-%s", var.istio_ip_name, var.name_suffix)
  node_count_current_per_zone = var.node_count_current_per_zone == 0 ? null : var.node_count_current_per_zone
  node_count_min_per_zone     = var.node_count_min_per_zone > var.node_count_initial_per_zone ? var.node_count_initial_per_zone : var.node_count_min_per_zone
  node_count_max_per_zone     = var.node_count_max_per_zone < var.node_count_initial_per_zone ? var.node_count_initial_per_zone : var.node_count_max_per_zone
  oauth_scopes                = ["cloud-platform"] # FULL ACCESS to all GCloud services. Limit them by IAM roles in 'gke_service_account' - see https://cloud.google.com/compute/docs/access/service-accounts#accesscopesiam
  master_private_ip_cidr      = "172.16.0.0/28"    # the cluster master's private IP will be assigned from this CIDR - https://cloud.google.com/nat/docs/gke-example#step_2_create_a_private_cluster 
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
}

resource "google_project_service" "container_api" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "networking_api" {
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

module "gke_service_account" {
  source            = "airasia/service_account/google"
  version           = "1.2.1"
  providers         = { google = google }
  name_suffix       = var.name_suffix
  name              = var.sa_name
  display_name      = var.sa_name
  description       = "Its IAM role(s) will specify the access-levels that the GKE node(s) may have"
  roles             = toset(concat(local.pre_defined_sa_roles, var.sa_roles))
  module_depends_on = [google_project_service.container_api.id]
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
    enable_private_endpoint = var.enable_private_endpoint
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

resource "google_container_node_pool" "node_pool" {
  provider           = google-beta
  name               = var.node_pool_name
  location           = local.gke_location
  version            = local.gke_node_version
  cluster            = google_container_cluster.k8s_cluster.name
  initial_node_count = var.node_count_initial_per_zone
  node_count         = local.node_count_current_per_zone
  autoscaling {
    min_node_count = local.node_count_min_per_zone
    max_node_count = local.node_count_max_per_zone
  }
  management {
    auto_repair  = true
    auto_upgrade = false
  }
  upgrade_settings {
    max_surge       = var.max_surge
    max_unavailable = var.max_unavailable
  }
  node_config {
    machine_type = var.machine_type
    disk_type    = var.disk_type
    disk_size_gb = var.disk_size_gb
    preemptible  = var.preemptible
    labels = {
      used_for = "gke"
      used_by  = google_container_cluster.k8s_cluster.name
    }
    service_account = module.gke_service_account.email
    oauth_scopes    = local.oauth_scopes
  }
  depends_on = [google_project_service.container_api]
  timeouts {
    create = var.node_pool_timeout
    update = var.node_pool_timeout
    delete = var.node_pool_timeout
  }
}

resource "google_container_node_pool" "auxiliary_node_pool" {
  count              = var.create_auxiliary_node_pool ? 1 : 0
  provider           = google-beta
  name               = "aux-${var.node_pool_name}"
  location           = local.gke_location
  version            = local.gke_node_version
  cluster            = google_container_cluster.k8s_cluster.name
  initial_node_count = var.auxiliary_node_pool_config.node_count_initial_per_zone
  node_count         = null
  autoscaling {
    min_node_count = var.auxiliary_node_pool_config.node_count_min_per_zone
    max_node_count = var.auxiliary_node_pool_config.node_count_max_per_zone
  }
  management {
    auto_repair  = true
    auto_upgrade = false
  }
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
  node_config {
    machine_type = var.auxiliary_node_pool_config.machine_type
    disk_type    = "pd-standard"
    disk_size_gb = var.auxiliary_node_pool_config.disk_size_gb
    preemptible  = false
    labels = {
      used_for = "gke-aux-node-pool"
      used_by  = google_container_cluster.k8s_cluster.name
    }
    service_account = module.gke_service_account.email
    oauth_scopes    = ["cloud-platform"]
  }
  depends_on = [google_project_service.container_api]
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

resource "kubernetes_namespace" "namespaces" {
  depends_on = [google_container_node_pool.node_pool]
  count      = length(var.namespaces)
  metadata {
    name   = var.namespaces[count.index].name
    labels = var.namespaces[count.index].labels
  }
  timeouts { delete = var.namespace_timeout }
}

resource "kubernetes_secret" "secrets" {
  depends_on = [kubernetes_namespace.namespaces]
  for_each   = var.secrets
  metadata {
    namespace = split(":", each.key)[0]
    name      = split(":", each.key)[1]
  }
  data = each.value
}

resource "google_compute_global_address" "static_ingress_ip" {
  count      = var.create_static_ingress_ip ? 1 : 0
  name       = local.ingress_ip_name
  depends_on = [google_project_service.networking_api]
  timeouts {
    create = var.ip_address_timeout
    delete = var.ip_address_timeout
  }
}

resource "google_compute_address" "static_istio_ip" {
  count      = var.create_static_istio_ip ? 1 : 0
  name       = local.istio_ip_name
  depends_on = [google_project_service.networking_api]
  timeouts {
    create = var.ip_address_timeout
    delete = var.ip_address_timeout
  }
}

data "google_client_config" "google_client" {}
