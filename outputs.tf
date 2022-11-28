output "hostname" {
  description = "Name of the kubernetes service"
  value       = kubernetes_service.mariadb.metadata[0].name
}

output "port" {
  description = "Port for the kubernetes service"
  value       = kubernetes_service.mariadb.spec[0].port[0].port
}

output "password_secret" {
  description = "Secret that is created with the database password"
  value       = local.create_password == 0 ? kubernetes_secret.mariadb[0].metadata[0].name : var.password_secret
}

output "password_key" {
  description = "Key for the database password in the secret"
  value       = var.password_key
}

output "name" {
  description = "Database name"
  value       = var.name
  depends_on = [
    kubernetes_stateful_set.mariadb
  ]
}

output "username" {
  description = "Username that can login to the databse"
  value       = var.username
  depends_on = [
    kubernetes_stateful_set.mariadb
  ]
}

output "type" {
  description = "Type of database deployed"
  value       = "mysql"
}
