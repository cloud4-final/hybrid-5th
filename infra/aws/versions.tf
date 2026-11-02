terraform {
  required_version = ">= 1.10" # S3 자체 잠금 기능이 1.10부터 지원됨

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # 6.x 안에서만 업데이트
    }
  }

  backend "s3" {
    bucket       = "jammy-hybrid-tfstate-2026"
    key          = "aws/terraform.tfstate" # 버킷 안 장부 파일 경로
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true # 동시 실행 방지 잠금 (DynamoDB 불필요)
  }
}
