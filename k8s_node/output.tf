output "instance_access" {
  value = "Access instance using : ssh ubuntu@${aws_instance.k8s_node.public_ip} -i ${replace(local.keypair_public_key, ".pub", "")}"
}