output "api_url" {
  description = "Endpoint base do API Gateway. O aluno faz POST em {api_url}/pedidos."
  value       = aws_apigatewayv2_api.api.api_endpoint
}

output "bucket_datalake" {
  description = "Bucket S3 onde os pedidos sao gravados."
  value       = terraform_data.bucket.output
}

output "dashboard_url" {
  description = "Link direto do dashboard de observabilidade da Fase 1."
  value       = "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards/dashboard/${aws_cloudwatch_dashboard.fase1.dashboard_name}"
}
