data "aws_caller_identity" "current" {}

locals {
  lab_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"
  # Nome do bucket do data lake unico por conta (account_id evita colisao global no S3).
  bucket_name = "pedeja-datalake-${data.aws_caller_identity.current.account_id}"
  # Layer publica do AWS Lambda Powertools (Logger + Metrics EMF + Tracer X-Ray).
  powertools_layer = "arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-x86_64:25"
}

# ---------------------------------------------------------------------------
# Data lake: onde os pedidos vao parar como arquivos JSON particionados por data
# ---------------------------------------------------------------------------
# A SCP do AWS Academy nega explicitamente `s3:GetBucketObjectLockConfiguration`.
# O recurso `aws_s3_bucket` do provider faz essa chamada ao ler o bucket de
# volta depois de criar, entao o apply cria o bucket e reprova em seguida com
# AccessDenied - deny em SCP nao e contornavel por permissao. Por isso o bucket
# nasce pela CLI, que nao faz essa leitura, e o Terraform so guarda o nome.
# O `output` deste recurso e o nome do bucket, e referencia-lo (em vez de
# repetir `local.bucket_name`) e o que faz o Terraform criar o bucket antes de
# quem depende dele.
resource "terraform_data" "bucket" {
  input = local.bucket_name

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if ! aws s3api head-bucket --bucket ${self.input} 2>/dev/null; then
        aws s3api create-bucket --bucket ${self.input} --region us-east-1 > /dev/null
        aws s3api wait bucket-exists --bucket ${self.input}
      fi
    EOT
  }

  # Provisioner de destroy so pode referenciar `self`, e e por isso que o nome
  # viaja no `input`. `rb --force` esvazia antes de apagar: os JSON que a
  # Lambda grava nao sao geridos por nenhum `aws_s3_object`, entao um
  # DeleteBucket simples falharia em bucket nao vazio. A guarda head-bucket
  # mantem o destroy verde quando o bucket ja nao existe.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if aws s3api head-bucket --bucket ${self.input} 2>/dev/null; then
        aws s3 rb "s3://${self.input}" --force > /dev/null
      fi
    EOT
  }
}

# ---------------------------------------------------------------------------
# Empacota o handler.py em zip que a Lambda consome
# ---------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/build/ingestao.zip"
}

resource "aws_lambda_function" "ingestao" {
  function_name    = "pedeja-ingestao"
  role             = local.lab_role_arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 15
  memory_size      = 128

  layers = [local.powertools_layer]

  tracing_config {
    mode = "Active" # liga o X-Ray: trace distribuido Lambda -> S3
  }

  environment {
    variables = {
      BUCKET_DATA_LAKE             = terraform_data.bucket.output
      POWERTOOLS_SERVICE_NAME      = "pedeja-ingestao"
      POWERTOOLS_METRICS_NAMESPACE = "PedeJa"
      POWERTOOLS_LOG_LEVEL         = "INFO"
    }
  }
}

# ---------------------------------------------------------------------------
# API Gateway HTTP API: entrega cada requisicao como EVENTO para a Lambda.
# A Lambda e event-driven desde o inicio: nao ha servidor escutando porta.
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "api" {
  name          = "pedeja-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ingestao.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_pedidos" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /pedidos"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestao.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Dashboard de observabilidade da Fase 1: os 4 golden signals + negocio.
# Latencia, Trafego (invocacoes), Erros e Saturacao (concorrencia) da Lambda,
# mais a metrica de negocio (faturamento por cidade) via EMF.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "fase1" {
  dashboard_name = "PedeJa-Fase1-Ingestao"
  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 2,
        properties = { markdown = "# PedeJa - Fase 1 (Ingestao API GW -> Lambda -> S3)\nOs **4 golden signals** da Lambda + metricas de **negocio**. Se a latencia sobe e os erros aparecem sob carga, e hora de evoluir a arquitetura." }
      },
      {
        type = "metric", x = 0, y = 2, width = 6, height = 6,
        properties = {
          title   = "Trafego - Invocacoes",
          region  = "us-east-1",
          metrics = [["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.ingestao.function_name, { stat = "Sum" }]]
        }
      },
      {
        type = "metric", x = 6, y = 2, width = 6, height = 6,
        properties = {
          title  = "Latencia - Duration (ms)",
          region = "us-east-1",
          metrics = [["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.ingestao.function_name, { stat = "Average" }],
          ["...", { stat = "p99" }]]
        }
      },
      {
        type = "metric", x = 12, y = 2, width = 6, height = 6,
        properties = {
          title   = "Erros",
          region  = "us-east-1",
          metrics = [["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.ingestao.function_name, { stat = "Sum" }]]
        }
      },
      {
        type = "metric", x = 18, y = 2, width = 6, height = 6,
        properties = {
          title   = "Saturacao - ConcurrentExecutions",
          region  = "us-east-1",
          metrics = [["AWS/Lambda", "ConcurrentExecutions", "FunctionName", aws_lambda_function.ingestao.function_name, { stat = "Maximum" }]]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 24, height = 6,
        properties = {
          title  = "Negocio - Faturamento por cidade (valor_pedido)",
          region = "us-east-1",
          view   = "timeSeries",
          metrics = [
            ["PedeJa", "valor_pedido", "service", "pedeja-ingestao", "cidade", "Sao Paulo", { stat = "Sum" }],
            ["...", "cidade", "Rio de Janeiro", { stat = "Sum" }],
            ["...", "cidade", "Curitiba", { stat = "Sum" }],
            ["...", "cidade", "Belo Horizonte", { stat = "Sum" }]
          ]
        }
      }
    ]
  })
}
