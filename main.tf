terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.8.0"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
}

resource "google_compute_network" "vpc_network" {
  name = "terraform-network"
}

resource "google_service_account" "vm_service_account" {
  account_id   = "vm-instance-sa"
  display_name = "VM Instance Service Account"
}

resource "google_project_iam_member" "vm_sa_monitoring_writer" {
  project = var.project
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.vm_service_account.email}"
}

resource "google_project_iam_member" "vm_sa_logs_writer" {
  project = var.project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.vm_service_account.email}"
}

resource "google_compute_disk" "persistent_disk" {
  name = "vm-persistent-disk"
  type = "pd-balanced"
  zone = var.zone
  size = 10
}

resource "google_compute_instance" "db_instance" {
  name         = "db-instance"
  machine_type = "e2-small"
  tags         = ["db"]
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  attached_disk {
    source = google_compute_disk.persistent_disk.id
    device_name = "persistent-disk-1"
  }

  network_interface {
    network = google_compute_network.vpc_network.name
    access_config {
    }
  }

  service_account {
    email  = google_service_account.vm_service_account.email
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_instance" "web_instance" {
  count        = var.scale
  name         = "web-instance-${count.index}"
  machine_type = "e2-small"
  tags         = ["web"]
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = google_compute_network.vpc_network.name
    access_config {
    }
  }

  service_account {
    email  = google_service_account.vm_service_account.email
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_instance_group" "web_instance_group" {
  name        = "web-instance-group"
  zone        = var.zone
  instances = google_compute_instance.web_instance[*].self_link

  named_port {
    name = "http"
    port = 80
  }
}

resource "google_compute_health_check" "http_health_check" {
  name                = "http-health-check"  
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2

  tcp_health_check {
    port = 80
  }
}

resource "google_compute_firewall" "allow_http" {
  name    = "terraform-network-allow-http"
  network = google_compute_network.vpc_network.name
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["web"]
}

resource "google_compute_firewall" "allow_health_check" {
  name = "terraform-network-allow-health-check"
  network = google_compute_network.vpc_network.name
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["web"]
}

resource "google_compute_firewall" "allow_db" {
  name    = "terraform-network-allow-db"
  network = google_compute_network.vpc_network.name
  allow {
    protocol = "tcp"
    ports    = ["3306"]
  }
  source_tags = ["web"]
  target_tags   = ["db"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "terraform-network-allow-ssh"
  network = google_compute_network.vpc_network.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["web", "db"]
}

output "db-ip" {
  value = google_compute_instance.db_instance.network_interface.0.network_ip
}

output "web-ip" {
  value = google_compute_instance.web_instance[*].network_interface.0.network_ip
}

output "external_ip" {
  value = google_compute_instance.web_instance[*].network_interface.0.access_config.0.nat_ip
}

resource "google_compute_backend_service" "web_backend_service" {
  name = "web-backend-service"
  port_name = "http"
  protocol = "HTTP"
  health_checks = [google_compute_health_check.http_health_check.id]

  backend {
    group = google_compute_instance_group.web_instance_group.id
  }
}

resource "google_compute_url_map" "default" {
  name = "default-url-map"
  default_service = google_compute_backend_service.web_backend_service.id
}

resource "google_compute_target_http_proxy" "http_proxy" {
  name = "http-load-balancer-proxy"
  url_map = google_compute_url_map.default.id
}

resource "google_compute_global_forwarding_rule" "http_forwarding_rule" {
  name = "http-forwarding-rule"
  target = google_compute_target_http_proxy.http_proxy.id
  port_range = "80"
}

output "lb_ip_address" {
  value = google_compute_global_forwarding_rule.http_forwarding_rule.ip_address
}
