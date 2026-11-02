provider "aws" {
  region = "ap-northeast-2"

  default_tags { # 이 코드로 만드는 모든 리소스에 자동 부착
    tags = {
      Project   = "jammy"
      Part      = "aws"
      ManagedBy = "terraform"
    }
  }
}
