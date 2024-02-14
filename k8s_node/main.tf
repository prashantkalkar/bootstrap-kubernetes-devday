terraform {
  required_version = "1.7.3"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "5.36.0"
    }
    http = {
      source = "hashicorp/http"
      version = "3.4.1"
    }
  }
}

provider "aws" {
  region = "ap-south-1"

  default_tags {
    tags = {
      Owner = var.person_name
      Project = "Devday"
    }
  }
}

provider "http" {}

data "aws_ami" "ubuntu-ami" {
  most_recent = true
  owners      = ["099720109477"]
  include_deprecated = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }
}

// ami-0f2e255ec956ade7f

data "aws_subnet" "selected" {
  id = var.public_subnet_id
}

resource "aws_instance" "k8s_node" {
  ami = data.aws_ami.ubuntu-ami.id
  associate_public_ip_address = true
  ebs_optimized = true
  iam_instance_profile = aws_iam_instance_profile.node_instance_profile.name
  instance_type = "t3a.medium"
  subnet_id = data.aws_subnet.selected.id
  key_name = aws_key_pair.key_pair.key_name
  vpc_security_group_ids = [aws_security_group.node_sg.id]
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_put_response_hop_limit = 3
    http_tokens = "optional"
    instance_metadata_tags = "enabled"
  }

  credit_specification {
    cpu_credits = "standard"
  }

  private_dns_name_options {
    hostname_type = "ip-name"
  }

  maintenance_options {
    auto_recovery = "default"
  }

  tags = {
    Name = "k8s_node_devday_${var.person_name}"
  }

  #force instance recreate on user data change
  user_data = <<-EOF
    #!/bin/bash

    echo "${filesha1("${path.module}/user_data.sh")}"
  EOF

  connection {
    host = aws_instance.k8s_node.public_ip
    user = "ubuntu"
    private_key = file(replace(local.keypair_public_key, ".pub", ""))
  }

  provisioner "file" {
    source = "${path.module}/user_data.sh"
    destination = "/home/ubuntu/user_data.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "ls -l",
      "chmod +x /home/ubuntu/user_data.sh",
      "sudo cloud-init status --wait --long",
      "/home/ubuntu/user_data.sh",
    ]
  }
}

locals {
  keypair_public_key = var.keypair_pub_file
}

resource "aws_key_pair" "key_pair" {
  key_name = "keypair_${var.person_name}"
  public_key = file(local.keypair_public_key)
}