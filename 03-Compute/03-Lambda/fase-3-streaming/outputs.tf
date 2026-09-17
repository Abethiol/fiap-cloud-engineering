output "api_url" {
  description = "Endpoint do API Gateway da Fase 3. O aluno faz POST em {api_url}/pedidos."
  value       = aws_apigatewayv2_api.api.api_endpoint
}

output "stream_name" {
  description = "Nome do Kinesis Data Stream de pedidos."
  value       = aws_kinesis_stream.pedidos.name
}

output "bucket_datalake" {
  description = "Bucket S3 onde os pedidos sao gravados."
  value       = terraform_data.bucket.output
}

output "dashboard_negocio_url" {
  description = "Painel de negocio: faturamento por cidade (responde a pergunta do lab)."
  value       = "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards/dashboard/${aws_cloudwatch_dashboard.negocio.dashboard_name}"
}

output "dashboard_golden_url" {
  description = "Painel de golden signals: latencia, trafego, erros, saturacao."
  value       = "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards/dashboard/${aws_cloudwatch_dashboard.golden.dashboard_name}"
}

output "glue_database" {
  description = "Database Glue que o Athena consulta."
  value       = aws_glue_catalog_database.pedeja.name
}

output "athena_workgroup" {
  description = "Workgroup do Athena com o local de resultados ja configurado."
  value       = aws_athena_workgroup.pedeja.name
}

output "athena_results" {
  description = "Prefixo S3 onde o Athena grava os resultados das queries."
  value       = "s3://${terraform_data.bucket.output}/athena-results/"
}
