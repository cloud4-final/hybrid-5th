provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project   = "jammy"
      Part      = "aws"
      Owner     = "hong" # 팀 규칙: owner 태그 필수
      ManagedBy = "terraform"
    }
  }
}
