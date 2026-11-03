# EC2가 이 역할을 쓸 수 있다고 허락
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "edge" {
  name               = "jammy-edge-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM 접속에 필요한 AWS 기본 권한
resource "aws_iam_role_policy_attachment" "edge_ssm" {
  role       = aws_iam_role.edge.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "edge" {
  name = "jammy-edge-profile"
  role = aws_iam_role.edge.name
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "edge_read_tskey" {
  name = "read-tailscale-authkey"
  role = aws_iam_role.edge.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter/jammy/tailscale/edge-authkey"
    }]
  })
}
