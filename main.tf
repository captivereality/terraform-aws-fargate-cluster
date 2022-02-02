 
# -----------------------------------------------------------
# -- AWS Fargate Module for Terraform
# --
# -- Terraform module that creates a fargate cluster and
# -- associated resources.
# -- ECS Cluster
# -- ECS Task defintion
# -- Cloudwatch logs
# -- IAM Permissions to:
# -- Log to Cloudwatch logs/S3
# -- Assume its own role
# -- ALB Load Balancer or NAT Gateway
# -- Public subnet for load balancer
# -- Private subnet for ECS Cluster (only acessible via lb)
# --
# -- Original Src: 
# -- https://github.com/PackagePortal/terraform-aws-fargate-cluster
# -----------------------------------------------------------

# ---------------------------------------------------------
# -- Local Variables
# ---------------------------------------------------------

locals {
  ecs_container_definitions = [
    {
      name        = "${var.env_name}-${var.app_name}",
      image       = var.image_name
      networkMode = "awcvpc",

      portMappings = [
        {
          containerPort = var.container_port,
          hostPort      = var.container_port,
          protocol      = var.container_protocol
        }
      ]

      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-group         = "${aws_cloudwatch_log_group.fargate.name}",
          awslogs-region        = "${var.region}",
          awslogs-stream-prefix = "ecs"
        }
      }

      environment = var.environment
    }
  ]

  https       = var.https_enabled == true
  nat_enabled = var.use_nat == true
}

# Reference resources
data "aws_availability_zones" "available" {
}

data "aws_vpc" "vpc" {
  id = var.vpc_id
}

# ---------------------------------------------------------
# -- Network Interfaces
# ---------------------------------------------------------

# Security group for public subnet holding load balancer
resource "aws_security_group" "alb" {
  name        = "${var.env_name}-${var.app_name}-alb"
  description = "Allow access on port 443 only to ALB"
  vpc_id      = data.aws_vpc.vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    self        = true
  }
}

# Allow ingress rule appropriate to HTTP Protocol used
resource "aws_security_group_rule" "tcp_443" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}


resource "aws_security_group_rule" "tcp_80" {
  count = local.https ? 0 : 1

  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

# Public subnet for ALB
resource "aws_subnet" "fargate_public" {
  count                   = var.az_count
  cidr_block              = cidrsubnet(data.aws_vpc.vpc.cidr_block, 8, var.cidr_bit_offset + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  vpc_id                  = data.aws_vpc.vpc.id
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.env_name} ${var.app_name} #${var.az_count + count.index} (public)"
  }
}

# Private subnet to hold fargate container
resource "aws_subnet" "fargate_ecs" {
  count             = var.az_count
  cidr_block        = cidrsubnet(data.aws_vpc.vpc.cidr_block, 8, var.cidr_bit_offset + var.az_count + count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  vpc_id            = data.aws_vpc.vpc.id

  tags = {
    Name = "${var.env_name} ${var.app_name} #${count.index} (private)"
  }
}

# Private subnet for the ECS - only allows access from the ALB
resource "aws_security_group" "fargate_ecs" {
  name        = "${var.env_name}-${var.app_name}-tasks"
  description = "allow inbound access from the ALB only"
  vpc_id      = data.aws_vpc.vpc.id

  ingress {
    protocol        = "tcp"
    from_port       = var.container_port
    to_port         = var.container_port
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
    self        = true
  }
}

# ---------------------------------------------------------
# -- Load Balancer
# ---------------------------------------------------------

resource "aws_alb" "fargate" {
  count           = local.nat_enabled ? 0 : 1
  name            = "${var.env_name}-${var.app_name}-alb"
  subnets         = aws_subnet.fargate_public.*.id
  security_groups = [aws_security_group.alb.id]

  access_logs {
    bucket  = aws_s3_bucket.fargate.id
    prefix  = "alb"
    enabled = true
  }

  depends_on = [aws_s3_bucket.fargate]
}

resource "aws_alb_target_group" "fargate" {
  count       = local.nat_enabled ? 0 : 1
  name        = "${var.env_name}-${var.app_name}-alb-tg2"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.vpc.id
  target_type = "ip"
}

resource "aws_alb_listener" "fargate_http" {
  count             = local.nat_enabled ? 0 : 1
  load_balancer_arn = aws_alb.fargate[count.index].id
  port              = "80"
  protocol          = "HTTP"
  certificate_arn   = ""

  default_action {
    target_group_arn = aws_alb_target_group.fargate[count.index].id
    type             = "forward"
  }
}

resource "aws_alb_listener" "fargate_https" {
  count             = local.nat_enabled ? 0 : local.https ? 1 : 0 # Only enable if not NAT and SSL enabled
  load_balancer_arn = aws_alb.fargate[count.index].id
  port              = "443"
  protocol          = "HTTPS"
  certificate_arn   = var.cert_arn

  default_action {
    target_group_arn = aws_alb_target_group.fargate[count.index].id
    type             = "forward"
  }
}

# ---------------------------------------------------------
# -- NAT Gateway (Optional)
# ---------------------------------------------------------

resource "aws_eip" "ip" {
  count = local.nat_enabled ? var.az_count : 0
  vpc   = true

  tags = {
    Name = "IP NAT Gateway ${var.env_name}-${var.app_name}"
  }
}

resource "aws_nat_gateway" "gw" {
  count         = local.nat_enabled ? var.az_count : 0
  allocation_id = aws_eip.ip[count.index].id
  subnet_id     = aws_subnet.fargate_public[count.index].id

  tags = {
    Name = "NAT Gateway ${var.env_name}-${var.app_name}"
  }
}

# ---------------------------------------------------------
# -- Elastic Container Service (ECS)
# ---------------------------------------------------------

resource "aws_ecs_task_definition" "fargate" {
  family                   = var.task_group_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu_units
  memory                   = var.ram_units
  execution_role_arn       = aws_iam_role.fargate_role.arn
  task_role_arn            = aws_iam_role.fargate_role.arn

  container_definitions = jsonencode(local.ecs_container_definitions)
}

resource "aws_ecs_cluster" "fargate" {
  name = "${var.env_name}-${var.app_name}-cluster"

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy {
    capacity_provider = var.capacity_provider
  }
}

resource "aws_ecs_service" "fargate" {
  depends_on = [
    aws_ecs_task_definition.fargate,
    aws_cloudwatch_log_group.fargate,
    aws_alb_listener.fargate_http,
    aws_alb_listener.fargate_https,
    aws_alb_target_group.fargate,
    aws_alb.fargate
  ]
  name                               = "${var.env_name}-${var.app_name}-service"
  cluster                            = aws_ecs_cluster.fargate.id
  task_definition                    = aws_ecs_task_definition.fargate.arn
  desired_count                      = var.desired_tasks
  deployment_maximum_percent         = var.maxiumum_healthy_task_percent
  deployment_minimum_healthy_percent = var.minimum_healthy_task_percent

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider
    weight            = 100
  }

  network_configuration {
    assign_public_ip = true
    security_groups  = [aws_security_group.fargate_ecs.id]
    subnets          = aws_subnet.fargate_ecs.*.id
  }

  dynamic "load_balancer" {
    for_each = local.nat_enabled ? [] : [1]

    content {
      target_group_arn = aws_alb_target_group.fargate[0].id # nb, Count will always be 0 if ALB used instead of NAT
      container_name   = "${var.env_name}-${var.app_name}"
      container_port   = var.container_port
    }
  }
}
