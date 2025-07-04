terraform {
  backend "gcs" {
    bucket = "chainguard-academy-terraform-state"
    prefix = "/ng-academy"
  }
}

provider "google" { project = var.project_id }
provider "google-beta" { project = var.project_id }

module "networking" {
  source  = "chainguard-dev/common/infra//modules/networking"
  version = "0.5.3"

  name          = var.name
  project_id    = var.project_id
  netnum_offset = 1 # Avoids replacement
  regions       = [var.primary-region]
}

resource "google_service_account" "chainguard-academy" {
  project = var.project_id

  account_id   = var.name
  display_name = "Chainguard Academy"
  description  = "The unprivileged service account as which Chainguard academy runs."
}

resource "google_cloud_run_v2_service" "chainguard-academy" {
  for_each = module.networking.regional-networks

  project  = var.project_id
  name     = var.name
  location = each.key
  ingress  = "INGRESS_TRAFFIC_ALL"

  launch_stage = "BETA" // Needed for vpc_access below

  template {
    vpc_access {
      network_interfaces {
        network    = each.value.network
        subnetwork = each.value.subnet
      }
      // Academy does not egress
      egress = "ALL_TRAFFIC"
    }

    service_account = google_service_account.chainguard-academy.email
    containers {
      image = var.image

      ports {
        container_port = 8080
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "public-services-are-unauthenticated" {
  for_each = google_cloud_run_v2_service.chainguard-academy

  project  = var.project_id
  location = each.key
  name     = each.value.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_dns_managed_zone" "edu-zone" {
  project     = var.project_id
  name        = "edu-chainguard-dev"
  dns_name    = "edu.chainguard.dev."

  dnssec_config {
    state = "on"
  }
}

// Put the above domain in front of our regional services.
module "serverless-gclb" {
  source  = "chainguard-dev/common/infra//modules/serverless-gclb"
  version = "0.6.163"

  name       = var.name
  project_id = var.project_id
  dns_zone   = google_dns_managed_zone.edu-zone.name

  // Regions are all of the places that we have backends deployed.
  // Regions must be removed from serving before they are torn down.
  regions         = keys(module.networking.regional-networks)
  serving_regions = keys(module.networking.regional-networks)

  public-services = {
    "edu.chainguard.dev" = {
      name = var.name
    }
  }
}
