# Log group for the app's container logs
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 7
}

# ECS cluster (Fargate, no servers)
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # adds cost; enable later if you want per-task metrics
  }
}

# Task definition: the blueprint (Terraform creates the first revision;
# the GitHub Actions pipeline will register newer revisions with new images)
resource "aws_ecs_task_definition" "app" {
  family                   = var.project_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = var.project_name
    image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential = true

    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]

    environment = [
      { name = "APP_VERSION", value = var.image_tag }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}

# ECS service: keeps the desired number of tasks running behind the ALB
resource "aws_ecs_service" "app" {
  name             = "${var.project_name}-web"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  health_check_grace_period_seconds = 30

  # Rolling update: never below 100% healthy, up to 200% during a deploy
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Automatic rollback when a deployment keeps failing
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Tasks in PRIVATE subnets, no public IPs
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.project_name
    container_port   = var.container_port
  }

  # The target group must be attached to the ALB before the service uses it
  depends_on = [aws_lb_listener.http]

  # The GitHub Actions pipeline deploys new task definition revisions.
  # Ignoring this attribute stops `terraform apply` from rolling the app back.
  lifecycle {
    ignore_changes = [task_definition]
  }
}