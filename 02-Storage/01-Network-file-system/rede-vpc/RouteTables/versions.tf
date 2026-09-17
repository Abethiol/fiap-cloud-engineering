terraform {
  # Fixado exatamente, e nao com "~>": sem pin, `terraform init` resolve a
  # versao mais nova do dia, e uma sala inteira acaba depurando diferenca de
  # provider em vez do servico da aula. Estes valores sao os que ja
  # provisionaram S3, Lambda, ECS e EFS com sucesso na conta do AWS Academy.
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.60.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "= 2.7.1"
    }
  }
}
