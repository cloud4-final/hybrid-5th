locals {
  # 퍼블릭 서브넷: AZ 이름 끝 글자 => 주소 범위
  public_subnets = {
    a = "10.200.1.0/24"
    c = "10.200.2.0/24"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.200.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true # EC2에 DNS 이름 부여 (SSM 접속 등에 필요)
  tags                 = { Name = "jammy-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "jammy-igw" }
}

resource "aws_subnet" "public" {
  for_each          = local.public_subnets # a, c 두 개를 반복 생성
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = "ap-northeast-2${each.key}"
  tags              = { Name = "jammy-public-${each.key}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"                  # VPC 밖으로 가는 모든 트래픽은
    gateway_id = aws_internet_gateway.main.id # 정문(IGW)으로
  }

  tags = { Name = "jammy-public-rt" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public # 서브넷마다 표지판 연결
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
