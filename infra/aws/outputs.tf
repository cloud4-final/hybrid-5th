output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = { for k, s in aws_subnet.public : k => s.id }
}

output "edge_a_public_ip" {
  value = aws_eip.edge_a.public_ip
}
