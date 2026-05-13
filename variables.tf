# Definimos las variables para no hardcodear todo si es posible
variable "vpc_id" {
  default = "vpc-0258bccb3effe2eb0"
}

variable "subnet_id" {
  default = "subnet-0323b4e6e5a5b5a54"
}

variable "subnet_id_2" {
  default = "subnet-07dfc764220cfe961"
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
