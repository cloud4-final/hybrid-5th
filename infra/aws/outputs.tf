output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = { for k, s in aws_subnet.public : k => s.id }
}

output "edge_public_ips" {
  value = { for k, e in aws_eip.edge : k => e.public_ip } # { a = "...", c = "..." }
}
