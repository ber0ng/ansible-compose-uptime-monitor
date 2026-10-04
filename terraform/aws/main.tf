# ami latest ubuntu 24.04 from canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Network
resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "vpc-${var.project}" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id
  tags   = { Name = "igw-${var.project}" }
}

resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.20.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "subnet-${var.project}-public" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "rt-${var.project}-public" }
}

resource "aws_route_table_association" "public-rta" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# Security group
resource "aws_security_group" "app_sg" {
  name        = "${var.project}-sg"
  description = "SSH from my IP, http from anywhere"
  vpc_id      = aws_vpc.main_vpc.id
  tags        = { Name = "sg-${var.project}" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh_rule" {
  security_group_id = aws_security_group.app_sg.id
  description       = "SSH from my ip only"
  cidr_ipv4         = var.my_ip
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "http_rule" {
  security_group_id = aws_security_group.app_sg.id
  description       = "HTTP on nginx"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "egress_rule" {
  security_group_id = aws_security_group.app_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# VM
resource "aws_key_pair" "deployer_kp" {
  key_name   = "${var.project}-deployer-kp"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_instance" "app_instance" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  key_name               = aws_key_pair.deployer_kp.key_name

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = { Name = "ec2-${var.project}-01" }
}

resource "aws_eip" "app_eip" {
  instance = aws_instance.app_instance.id
  domain   = "vpc"
  tags     = { Name = "eip-${var.project}" }
}
