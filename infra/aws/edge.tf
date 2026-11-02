# 최신 Ubuntu 24.04 이미지 자동 선택 (거점과 같은 OS)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical 공식 계정
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_instance" "edge_a" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public["a"].id
  vpc_security_group_ids = [aws_security_group.edge.id]       # 도어락
  iam_instance_profile   = aws_iam_instance_profile.edge.name # SSM 출입증
  user_data              = file("${path.module}/userdata/edge.sh")

  metadata_options {
    http_tokens = "required" # IMDSv2: 서버 내부 정보 탈취 방지
  }

  tags = { Name = "jammy-edge-a" }
}

# 고정 공인 IP
resource "aws_eip" "edge_a" {
  instance = aws_instance.edge_a.id
  domain   = "vpc"
  tags     = { Name = "jammy-edge-a-eip" }
}
