terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Remote state best practice (S3 + DynamoDB). Will be configured later.
//  backend "s3" {
//    bucket         = "zoo-negara-tfstate-unique123"  # change to your unique bucket
//    key            = "terraform/state"
//    region         = "ap-southeast-1"
//    dynamodb_table = "terraform-lock"
//    encrypt        = true
//  }
}

provider "aws" {
  region = var.aws_region
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "zoo-vpc"
  }
}

# Public Subnets (across 2 AZs for ALB requirement)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "zoo-public-${count.index + 1}"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "zoo-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security Group for Web Servers
resource "aws_security_group" "web_sg" {
  name        = "zoo-web-sg"
  description = "Allow HTTP, SSH (for Ansible)"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # In production, restrict to a bastion IP!
  }

  ingress {
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # node_exporter only from within VPC
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "zoo-web-sg" }
}

# ALB Security Group
resource "aws_security_group" "alb_sg" {
  name        = "zoo-alb-sg"
  description = "Allow HTTP from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Launch Template
resource "aws_launch_template" "web" {
  name_prefix   = "zoo-web-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Basic initialization; main config via Ansible
    apt-get update -y
    apt-get install -y python3
    EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "zoo-web"
      Environment = "prod"
    }
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "web_asg" {
  name                = "zoo-web-asg"
  vpc_zone_identifier = aws_subnet.public[*].id
  desired_capacity    = 2
  max_size            = 3
  min_size            = 1
  target_group_arns   = [aws_lb_target_group.web_tg.arn]

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "zoo-web-asg"
    propagate_at_launch = true
  }
}

# Application Load Balancer
resource "aws_lb" "web_alb" {
  name               = "zoo-web-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "web_tg" {
  name     = "zoo-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# S3 bucket for artifacts & backups (versioned, encrypted)
resource "aws_s3_bucket" "artifacts" {
  bucket = var.artifact_bucket_name
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ------------------------------
# Monitoring server and security
# ------------------------------

resource "aws_iam_role" "monitoring_role" {
  name = "zoo-monitoring-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "monitoring_policy" {
  name        = "zoo-monitoring-policy"
  description = "Allow EC2 describe for Prometheus service discovery"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "monitoring_attach" {
  role       = aws_iam_role.monitoring_role.name
  policy_arn = aws_iam_policy.monitoring_policy.arn
}

resource "aws_iam_instance_profile" "monitoring_profile" {
  name = "zoo-monitoring-profile"
  role = aws_iam_role.monitoring_role.name
}

resource "aws_security_group" "monitoring_sg" {
  name        = "zoo-monitoring-sg"
  description = "Allow Prometheus, Grafana, SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "zoo-monitoring-sg" }
}

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  key_name               = var.key_name
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.monitoring_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring_profile.name

  tags = { Name = "zoo-monitoring" }
}

output "monitoring_public_ip" {
  value = aws_instance.monitoring.public_ip
}
