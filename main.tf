data "aws_ami" "al2" {
  owners      = ["amazon"]
  most_recent = true
  name_regex  = "^amzn2-ami-hvm-2.0.\\d+-x86_64-gp2$"
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-2.*"]
  }
}

resource "tls_private_key" "key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "key" {
  key_name   = "mykey" 
  public_key = tls_private_key.key.public_key_openssh
  provisioner "local-exec" { 
    command = "echo '${tls_private_key.key.private_key_pem}' > ./mykey.pem && chmod 600 ./mykey.pem"
  }
}

resource "aws_instance" "gitea" {
  ami           = data.aws_ami.al2.id
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.gitea.id]
  key_name               = aws_key_pair.key.key_name
  user_data              = <<HEREDOC
  #!/bin/bash
  sudo yum update -y
  sudo amazon-linux-extras install docker
  sudo service docker start
  sudo usermod -a -G docker ec2-user
  sudo curl -L "https://github.com/docker/compose/releases/download/1.23.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
HEREDOC

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
      "mkdir /tmp/gitea",
    ]
  }

  provisioner "file" {
    source      = "docker-compose.yml"
    destination = "/tmp/docker-compose.yml"
  }

  provisioner "remote-exec" {
    inline = [
      "cd /tmp/gitea",
      "/usr/local/bin/docker-compose up -d",
    ]
  }

  connection {
    host        = aws_instance.gitea.public_ip
    type        = "ssh"
    user        = "ec2-user"
    private_key = tls_private_key.key.private_key_pem
  }
}

resource "aws_security_group" "gitea" {
  name        = "Gitea Server"
  description = "allows custom ssh and www"

  ingress {
    from_port = 3000
    to_port = 3000
    protocol = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 22
    to_port = 22
    protocol = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 80
    to_port = 80
    protocol = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = "22"
    to_port     = "22"
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "gitealb" {
  name        = "Gitea ALB"
  description = "allows http and https"

  ingress {
    from_port = 443
    to_port = 443
    protocol = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_lb_target_group" "tg" {
  name        = "gitea-tg"
  port        = 3000
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_lb_target_group_attachment" "tga" {
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.gitea.id
  port             = 3000
}

resource "aws_lb" "lb" {
  name               = "gitea-lb"
  internal           = false
  security_groups    = [aws_security_group.gitealb.id]
  load_balancer_type = "application"
  subnets            = toset(data.aws_subnets.default.ids)
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.lb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}