# Definimos las variables para no hardcodear todo si es posible
variable "vpc_id" {
  default = "vpc-01df9585efc0ea059"
}

variable "subnet_id" {
  default = "subnet-0d611864eb142dfec"
}

variable "subnet_id_2" {
  default = "subnet-0a6329af9a75bf7ff"
}

variable "ami_id" {
  default = "ami-040e163049fd403ec" # Amazon Linux 2023
}

variable "key_name" {
  default = "vockey"
}

variable "instance_type" {
  default = "t3.micro"
}
