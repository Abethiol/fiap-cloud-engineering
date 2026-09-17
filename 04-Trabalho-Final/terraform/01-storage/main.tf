data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

# AMI Amazon Linux 2 mais recente (traz o SSM agent pre-instalado -> acesso sem SSH).
data "aws_ssm_parameter" "linux_ami" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

locals {
  # Data lake unico por conta (account_id evita colisao no namespace global do S3).
  bucket_name = "pedeja-datalake-${data.aws_caller_identity.current.account_id}"
}

# ---------------------------------------------------------------------------
# Rede: VPC propria e autossuficiente (o Trabalho Final nao depende de nenhuma
# demo ter rodado antes). Uma VPC com subnet publica e internet gateway basta.
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "trabalho-final-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "trabalho-final-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "trabalho-final-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "trabalho-final-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security group: libera NFS (2049) para o mount do EFS. Nao abre porta 22 —
# o acesso a EC2 e via SSM Session Manager (sem SSH), como nas demos.
resource "aws_security_group" "efs" {
  name   = "trabalho-final-efs-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["10.20.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "trabalho-final-efs-sg" }
}

# ---------------------------------------------------------------------------
# Data lake S3: destino da migracao (raw/), do processamento (resumo/) e da API.
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
# EFS: o "servidor de arquivos legado" da PedeJa. O user-data da EC2 planta os
# 10 pedidos aqui dentro, simulando dados que ja existiam antes da migracao.
# ---------------------------------------------------------------------------
resource "aws_efs_file_system" "legado" {
  performance_mode = "generalPurpose"
  tags             = { Name = "pedeja-efs-legado" }
}

resource "aws_efs_mount_target" "legado" {
  file_system_id  = aws_efs_file_system.legado.id
  subnet_id       = aws_subnet.public.id
  security_groups = [aws_security_group.efs.id]
}

# ---------------------------------------------------------------------------
# EC2: onde o aluno entra via SSM para rodar a migracao EFS -> S3.
# Usa LabInstanceProfile (perfil pre-criado do Academy, da acesso SSM + S3).
# O user-data monta o EFS e planta os pedidos.json dentro dele.
# ---------------------------------------------------------------------------
resource "aws_instance" "migracao" {
  ami                    = data.aws_ssm_parameter.linux_ami.value
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.efs.id]
  iam_instance_profile   = "LabInstanceProfile"
  depends_on             = [aws_efs_mount_target.legado]

  tags = { Name = "pedeja-migracao-instance" }

  # Planta os pedidos no EFS. Cada pedido vira um arquivo .json, como se o
  # sistema legado tivesse gravado um arquivo por pedido no file server.
  #
  # Montagem via IP do mount target (nao pelo DNS fs-xxx.efs...): no Learner Lab
  # o DNS do EFS costuma nao resolver e o fallback do amazon-efs-utils depende de
  # botocore (ausente na AMI) — montar por IP com NFS 4.1 e a forma robusta. O
  # `set -e` + o teste `mountpoint` garantem que, se o mount falhar, o boot NAO
  # planta os pedidos no disco local (evita "migrar do EFS" sem tocar o EFS).
  user_data = <<-EOF
    #!/bin/bash -xe
    yum install -y nfs-utils jq
    mkdir -p /efs
    for i in $(seq 1 30); do
      if mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
        ${aws_efs_mount_target.legado.ip_address}:/ /efs; then
        break
      fi
      echo "mount target ainda nao pronto, tentativa $i; aguardando..."
      sleep 10
    done
    mountpoint -q /efs  # aborta o user-data (set -e) se o EFS nao montou
    mkdir -p /efs/pedidos
    cat > /tmp/pedidos.json <<'PEDIDOS'
${file("${path.module}/../../dados/pedidos.json")}
PEDIDOS
    # Explode o array em um arquivo por pedido dentro do EFS (formato do legado).
    jq -c '.[]' /tmp/pedidos.json | while read -r p; do
      id=$(echo "$p" | jq -r '.pedido_id')
      echo "$p" > /efs/pedidos/$id.json
    done
    chown -R ec2-user:ec2-user /efs/pedidos
  EOF
}

