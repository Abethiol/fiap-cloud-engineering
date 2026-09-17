output "bucket_datalake" {
  description = "Nome do bucket S3 do data lake (destino da migracao)."
  value       = terraform_data.bucket.output
}

output "instance_id" {
  description = "ID da EC2 de migracao (use para abrir a sessao SSM)."
  value       = aws_instance.migracao.id
}

output "efs_id" {
  description = "ID do EFS legado onde os pedidos foram plantados."
  value       = aws_efs_file_system.legado.id
}

output "efs_mount_ip" {
  description = "IP do mount target do EFS (usado para montar via NFS por IP)."
  value       = aws_efs_mount_target.legado.ip_address
}
