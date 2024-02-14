data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

resource "aws_security_group" "node_sg" {
  name_prefix = "k8s_node_sg_${var.person_name}"
  description = "SG for k8s_node"
  vpc_id = data.aws_vpc.vpc.id

  lifecycle {
    create_before_destroy = true
  }

  timeouts {
    delete = "2m"
  }
}

resource "aws_vpc_security_group_ingress_rule" "allow_ssh_access" {
  ip_protocol = "tcp"
  cidr_ipv4 = local.ipv4
  from_port = 22
  to_port = 22

  security_group_id = aws_security_group.node_sg.id
}

resource "aws_vpc_security_group_egress_rule" "allow_outgoing_ipv4" {
  ip_protocol = "-1"
  cidr_ipv4 = "0.0.0.0/0"

  security_group_id = aws_security_group.node_sg.id
}

resource "aws_vpc_security_group_egress_rule" "allow_outgoing_ipv6" {
  ip_protocol = "-1"
  cidr_ipv6 = "::/0"

  security_group_id = aws_security_group.node_sg.id
}

data "http" "my_ip" {
  url = "http://ipv4.icanhazip.com"
}

locals {
  ipv4 = "${chomp(data.http.my_ip.response_body)}/32"
}