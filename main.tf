terraform {
  required_version = ">= 0.12.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.1"
    }
  }
}

locals {
  selector_labels = {
    "app.kubernetes.io/name"     = "mariadb"
    "app.kubernetes.io/instance" = "master"
    "app.kubernetes.io/part-of"  = lookup(var.labels, "app.kubernetes.io/part-of", var.object_prefix)
  }
  common_labels = merge(var.labels, local.selector_labels, {
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/component"  = "mariadb"
  })
  password_file = anytrue([
    contains(keys(var.env), "MARIADB_ROOT_PASSWORD_FILE"),
    contains(keys(var.env), "MARIADB_PASSWORD_FILE"),
  ]) ? true : false
  create_password = anytrue([local.password_file, length(var.password_secret) > 0]) ? false : true
  env_secret = local.password_file ? var.env_secret : flatten([[
    {
      name   = "MARIADB_PASSWORD",
      secret = length(var.password_secret) == 0 ? kubernetes_secret.mariadb[0].metadata[0].name : var.password_secret,
      key    = var.password_key
    },
    {
      name   = "MARIADB_ROOT_PASSWORD",
      secret = length(var.password_secret) == 0 ? kubernetes_secret.mariadb[0].metadata[0].name : var.password_secret,
      key    = var.password_key_root
    }
  ], var.env_secret])
  healthcheck_script = <<EOF
  sqlpass="$${MARIADB_ROOT_PASSWORD:-}"
  if [[ -f "$${MARIADB_ROOT_PASSWORD_FILE:-}" ]]; then
    sqlpass=$(cat "$MARIADB_ROOT_PASSWORD_FILE")
  fi
  mysqladmin status -uroot -p"$${sqlpass}"
  EOF
  healthcheck_cmd    = ["/bin/bash", "-ce", local.healthcheck_script]
}

resource "kubernetes_stateful_set" "mariadb" {
  timeouts {
    create = var.timeout_create
    update = var.timeout_update
    delete = var.timeout_delete
  }
  metadata {
    namespace   = var.namespace
    name        = var.object_prefix
    labels      = local.common_labels
    annotations = var.annotations
  }
  wait_for_rollout = var.wait_for_rollout
  spec {
    pod_management_policy  = var.pod_management_policy
    replicas               = var.replicas
    revision_history_limit = var.revision_history
    service_name           = kubernetes_service.mariadb.metadata[0].name
    selector {
      match_labels = local.selector_labels
    }
    update_strategy {
      type = var.update_strategy
      dynamic "rolling_update" {
        for_each = var.update_strategy == "RollingUpdate" ? [1] : []
        content {
          partition = var.update_partition
        }
      }
    }
    template {
      metadata {
        labels      = local.selector_labels
        annotations = var.template_annotations
      }
      spec {
        service_account_name = length(var.service_account_name) > 0 ? var.service_account_name : null
        dynamic "security_context" {
          for_each = var.security_context_enabled ? [1] : []
          content {
            run_as_non_root = true
            run_as_user     = var.security_context_uid
            run_as_group    = var.security_context_gid
            fs_group        = var.security_context_gid
          }
        }
        container {
          image = format("%s:%s", var.image_name, var.image_tag)
          name  = regex("[[:alnum:]]+$", var.image_name)
          resources {
            limits = {
              cpu    = var.resources_limits_cpu
              memory = var.resources_limits_memory
            }
            requests = {
              cpu    = var.resources_requests_cpu
              memory = var.resources_requests_memory
            }
          }
          port {
            name           = "sql"
            protocol       = "TCP"
            container_port = kubernetes_service.mariadb.spec[0].port[0].target_port
          }
          env {
            name  = "MARIADB_DATABASE"
            value = var.name
          }
          env {
            name  = "MARIADB_USER"
            value = var.username
          }
          dynamic "env" {
            for_each = var.env
            content {
              name  = env.key
              value = env.value
            }
          }
          dynamic "env" {
            for_each = [for env_var in local.env_secret : {
              name   = env_var.name
              secret = env_var.secret
              key    = env_var.key
            }]
            content {
              name = env.value["name"]
              value_from {
                secret_key_ref {
                  name = env.value["secret"]
                  key  = env.value["key"]
                }
              }
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/bitnami/mariadb"
          }
          volume_mount {
            name       = "config"
            mount_path = "/opt/bitnami/mariadb/conf/my.cnf"
            sub_path   = "my.cnf"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/opt/bitnami/mariadb/tmp/"
          }
          dynamic "readiness_probe" {
            for_each = var.readiness_probe_enabled ? [1] : []
            content {
              initial_delay_seconds = var.readiness_probe_initial_delay
              period_seconds        = var.readiness_probe_period
              timeout_seconds       = var.readiness_probe_timeout
              success_threshold     = var.readiness_probe_success
              failure_threshold     = var.readiness_probe_failure
              exec {
                command = local.healthcheck_cmd
              }
            }
          }
          dynamic "liveness_probe" {
            for_each = var.liveness_probe_enabled ? [1] : []
            content {
              initial_delay_seconds = var.liveness_probe_initial_delay
              period_seconds        = var.liveness_probe_period
              timeout_seconds       = var.liveness_probe_timeout
              success_threshold     = var.liveness_probe_success
              failure_threshold     = var.liveness_probe_failure
              exec {
                command = local.healthcheck_cmd
              }
            }
          }
          dynamic "startup_probe" {
            for_each = var.startup_probe_enabled ? [1] : []
            content {
              initial_delay_seconds = var.startup_probe_initial_delay
              period_seconds        = var.startup_probe_period
              timeout_seconds       = var.startup_probe_timeout
              success_threshold     = var.startup_probe_success
              failure_threshold     = var.startup_probe_failure
              exec {
                command = local.healthcheck_cmd
              }
            }
          }
        }
        volume {
          name = "data"
          dynamic "empty_dir" {
            for_each = length(var.pvc_name) > 0 ? [] : [1]
            content {
              medium     = var.empty_dir_medium
              size_limit = var.empty_dir_size
            }
          }
          dynamic "persistent_volume_claim" {
            for_each = length(var.pvc_name) > 0 ? [1] : []
            content {
              claim_name = var.pvc_name
              read_only  = false
            }
          }
        }
        volume {
          name = "config"
          config_map {
            name         = kubernetes_config_map.mariadb.metadata[0].name
            default_mode = "0644"
            optional     = false
          }
        }
        volume {
          name = "tmp"
          empty_dir {
            medium     = "Memory"
            size_limit = "5Mi"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mariadb" {
  metadata {
    namespace   = var.namespace
    name        = var.object_prefix
    labels      = local.common_labels
    annotations = var.service_annotations
  }
  spec {
    selector                = local.selector_labels
    session_affinity        = var.service_session_affinity
    type                    = var.service_type
    external_traffic_policy = contains(["LoadBalancer", "NodePort"], var.service_type) ? var.service_traffic_policy : null
    port {
      name        = "sql"
      protocol    = "TCP"
      target_port = 3306
      port        = var.service_port
    }
  }
}

resource "kubernetes_secret" "mariadb" {
  count = local.create_password ? 1 : 0
  metadata {
    namespace = var.namespace
    name      = var.object_prefix
    labels    = local.common_labels
  }
  data = {
    (var.password_key_root) = random_password.root_password[0].result
    (var.password_key)      = random_password.password[0].result
  }
}

resource "random_password" "root_password" {
  count   = local.create_password ? 1 : 0
  length  = var.password_autocreate_length
  special = var.password_autocreate_special
}

resource "random_password" "password" {
  count   = local.create_password ? 1 : 0
  length  = var.password_autocreate_length
  special = var.password_autocreate_special
}

resource "kubernetes_config_map" "mariadb" {
  metadata {
    namespace = var.namespace
    name      = var.object_prefix
    labels    = local.common_labels
  }

  data = {
    "my.cnf" = <<EOF
[mysqld]
skip-name-resolve
explicit_defaults_for_timestamp
basedir=/opt/bitnami/mariadb
plugin_dir=/opt/bitnami/mariadb/plugin
port=3306
socket=/opt/bitnami/mariadb/tmp/mysql.sock
tmpdir=/opt/bitnami/mariadb/tmp
max_allowed_packet=16M
bind-address=0.0.0.0
pid-file=/opt/bitnami/mariadb/tmp/mysqld.pid
log-error=/opt/bitnami/mariadb/logs/mysqld.log
character-set-server=UTF8
collation-server=utf8_general_ci

[client]
port=3306
socket=/opt/bitnami/mariadb/tmp/mysql.sock
default-character-set=UTF8
plugin_dir=/opt/bitnami/mariadb/plugin

[manager]
port=3306
socket=/opt/bitnami/mariadb/tmp/mysql.sock
pid-file=/opt/bitnami/mariadb/tmp/mysqld.pid"
EOF
  }

  binary_data = {
  }
}
