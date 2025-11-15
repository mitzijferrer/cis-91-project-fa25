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

resource "google_compute_firewall" "allow_ssh" {
  name    = "terraform-network-allow-ssh"
  network = google_compute_network.vpc_network.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["web"]
}

resource "google_service_account" "vm_service_account" {
  account_id   = "vm-instance-sa"
  display_name = "VM Instance Service Account"
}

resource "google_compute_disk" "persistent_disk" {
  name = "vm-persistent-disk"
  type = "pd-balanced"
  zone = var.zone
  size = 10
}

resource "google_compute_instance" "vm_instance" {
  name         = "terraform-instance"
  machine_type = "e2-small"
  tags         = ["web", "dev"]
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

output "ip" {
  value = google_compute_instance.vm_instance.network_interface.0.network_ip
}
output "external_ip" {
  value = google_compute_instance.vm_instance.network_interface.0.access_config.0.nat_ip
}
