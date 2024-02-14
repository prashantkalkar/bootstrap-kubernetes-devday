variable "person_name" {
  type = string
}

variable "keypair_pub_file" {
  type = string
  default = "~/.ssh/id_rsa.pub"
}

variable "public_subnet_id" {
  type = string
}

variable "vpc_name" {
  type = string
}