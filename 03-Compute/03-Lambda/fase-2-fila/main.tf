data "aws_caller_identity" "current" {}

locals {
  lab_role_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"
  bucket_name      = "pedeja-datalake-${data.aws_caller_identity.current.account_id}"
  powertools_layer = "arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-x86_64:25"
}

# Cada fase e autossuficiente: cria seu proprio data lake.
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
# Fila SQS (buffer) + DLQ (dead-letter queue para mensagens que falham)
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  name = "pedeja-pedidos-dlq"
}

resource "aws_sqs_queue" "pedidos" {
  name                       = "pedeja-pedidos"
  visibility_timeout_seconds = 90 # >= timeout da Lambda consumidora
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3 # apos 3 falhas, a mensagem vai para a DLQ
  })
}

# ---------------------------------------------------------------------------
# Lambda PRODUTORA: API GW -> enfileira no SQS (responde em ms)
# ---------------------------------------------------------------------------
data "archive_file" "produtor_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-produtor"
  output_path = "${path.module}/build/produtor.zip"
}

resource "aws_lambda_function" "produtor" {
  function_name    = "pedeja-produtor"
  role             = local.lab_role_arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.produtor_zip.output_path
  source_code_hash = data.archive_file.produtor_zip.output_base64sha256
  timeout          = 15
  memory_size      = 128
  layers           = [local.powertools_layer]

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      QUEUE_URL                    = aws_sqs_queue.pedidos.url
      POWERTOOLS_SERVICE_NAME      = "pedeja-produtor"
      POWERTOOLS_METRICS_NAMESPACE = "PedeJa"
      POWERTOOLS_LOG_LEVEL         = "INFO"
    }
  }
}

# ---------------------------------------------------------------------------
# Lambda CONSUMIDORA: disparada pelo SQS (event source mapping) -> grava no S3
# ---------------------------------------------------------------------------
data "archive_file" "consumidor_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-consumidor"
  output_path = "${path.module}/build/consumidor.zip"
}

resource "aws_lambda_function" "consumidor" {
  function_name    = "pedeja-consumidor"
  role             = local.lab_role_arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.consumidor_zip.output_path
  source_code_hash = data.archive_file.consumidor_zip.output_base64sha256
  timeout          = 60
  memory_size      = 128
  layers           = [local.powertools_layer]

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      BUCKET_DATA_LAKE             = terraform_data.bucket.output
      POWERTOOLS_SERVICE_NAME      = "pedeja-consumidor"
      POWERTOOLS_METRICS_NAMESPACE = "PedeJa"
      POWERTOOLS_LOG_LEVEL         = "INFO"
    }
  }
}

# O gatilho: cada lote de ate 10 mensagens do SQS invoca a Lambda consumidora.
resource "aws_lambda_event_source_mapping" "sqs_to_consumidor" {
  event_source_arn = aws_sqs_queue.pedidos.arn
  function_name    = aws_lambda_function.consumidor.arn
  batch_size       = 10
}

# ---------------------------------------------------------------------------
# API Gateway -> Lambda produtora
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "api" {
  name          = "pedeja-api-fase2"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.produtor.invoke_arn
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
  function_name = aws_lambda_function.produtor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Dashboard Fase 2: golden signals das DUAS lambdas + profundidade da fila
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "fase2" {
  dashboard_name = "PedeJa-Fase2-Fila"
  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 2,
        properties = { markdown = "# PedeJa - Fase 2 (API GW -> Produtor -> SQS -> Consumidor -> S3)\nA **fila desacopla**: o produtor responde rapido e a fila absorve o pico. Observe a **profundidade da fila** subir e baixar, e a **DLQ** capturar o que falha." }
      },
      {
        type = "metric", x = 0, y = 2, width = 8, height = 6,
        properties = {
          title   = "Fila - Mensagens visiveis (backlog)",
          region  = "us-east-1",
          metrics = [["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.pedidos.name, { stat = "Maximum" }]]
        }
      },
      {
        type = "metric", x = 8, y = 2, width = 8, height = 6,
        properties = {
          title  = "Latencia - Produtor vs Consumidor (ms)",
          region = "us-east-1",
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.produtor.function_name, { stat = "Average", label = "produtor" }],
            ["...", aws_lambda_function.consumidor.function_name, { stat = "Average", label = "consumidor" }]
          ]
        }
      },
      {
        type = "metric", x = 16, y = 2, width = 8, height = 6,
        properties = {
          title   = "DLQ - mensagens que falharam",
          region  = "us-east-1",
          metrics = [["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.dlq.name, { stat = "Maximum" }]]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 12, height = 6,
        properties = {
          title  = "Trafego - enfileirados vs processados",
          region = "us-east-1",
          metrics = [
            ["PedeJa", "pedidos_enfileirados", "service", "pedeja-produtor", { stat = "Sum", label = "enfileirados" }],
            ["PedeJa", "pedidos_processados", "service", "pedeja-consumidor", { stat = "Sum", label = "processados" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 8, width = 12, height = 6,
        properties = {
          title   = "Erros do consumidor",
          region  = "us-east-1",
          metrics = [["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.consumidor.function_name, { stat = "Sum" }]]
        }
      }
    ]
  })
}
