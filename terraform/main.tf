# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


variable "project_id" {
  description = "Project ID of the cloud resource."
  type        = string
}
variable "oauth_client_id" {
  description = "OAuth Client ID for IAP."
  type        = string
}
variable "oauth_client_secret" {
  description = "OAuth Client Secret for IAP."
  type        = string
}
variable "comfyui_domain" {
  description = "Your custom domain or subdomain."
  type        = string
}
variable "region" {
  description = "Region to set for gcp resource deploy."
  type        = string
  default     = "us-central1"
}
variable "filestore_zone" {
  description = "Zone to set for filestore nfs server, should be same zone with gke node."
  type        = string
  default     = "us-central1-f"
}
variable "cluster_location" {
  description = "gke cluster location choose a zone or region."
  type        = string
  default     = "us-central1-f"
}
variable "gke_autopilot_network_tags" {
  description = "Network tags for GKE Autopilot cluster"
  type        = list(string)
  default     = ["gke-autopilot"]
}

module "agones_gcp_res" {
  source                          = "./modules/agones/gcp-res"
  project_id                      = var.project_id
  region                          = var.region
  filestore_zone                  = var.filestore_zone
  cluster_location                = var.cluster_location
  gke_autopilot_network_tags      = var.gke_autopilot_network_tags
  cloudfunctions_source_code_path = "../cloud-function/"
}

module "agones_build_image" {
  source            = "./modules/agones/cloud-build"
  artifact_registry = module.agones_gcp_res.artifactregistry_url
}

module "helm_agones" {
  source               = "./modules/agones/helm-agones"
  project_id           = var.project_id
  gke_cluster_name     = module.agones_gcp_res.kubernetes_cluster_name
  gke_cluster_location = module.agones_gcp_res.gke_location
  agones_version       = "1.53.0"
}

output "comfyui_image" {
  value       = module.agones_build_image.comfyui_image
  description = "comfyui image"
}

output "nginx_image" {
  value       = module.agones_build_image.nginx_image
  description = "nginx with lua ingress image"
}

output "game_server_image" {
  value       = module.agones_build_image.game_server_image
  description = "simple game server image"
}

output "artifactregistry_name" {
  value       = module.agones_gcp_res.artifactregistry_name
  description = "artifact registry name"
}

output "google_filestore_reserved_ip_range" {
  value       = module.agones_gcp_res.google_filestore_reserved_ip_range
  description = "Filestore NFS share IP"
}

output "google_redis_instance_host" {
  value       = module.agones_gcp_res.google_redis_instance_host
  description = "Redis Host"
}


