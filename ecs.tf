# ECS Cluster (EC2 launch type) with Container Insights
resource "aws_ecs_cluster" "this" {
  name = "${var.service_name}-cluster"

  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"
      log_configuration {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.ecs_exec.name
      }
    }
  }

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, {
    Name = "${var.service_name}-cluster"
  })
}

# ECS Capacity Provider
resource "aws_ecs_capacity_provider" "this" {
  name = "${var.service_name}-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      maximum_scaling_step_size = 2
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 90
    }
  }

  tags = merge(var.tags, {
    Name = "${var.service_name}-capacity-provider"
  })
}

# Associate capacity provider with cluster
resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  capacity_providers = [aws_ecs_capacity_provider.this.name]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = aws_ecs_capacity_provider.this.name
  }
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.service_name}"
  retention_in_days = 30

  tags = merge(var.tags, {
    Name = "/ecs/${var.service_name}"
  })
}

resource "aws_cloudwatch_log_group" "ecs_exec" {
  name              = "/ecs/exec/${var.service_name}"
  retention_in_days = 7

  tags = merge(var.tags, {
    Name = "/ecs/exec/${var.service_name}"
  })
}

# ECS Task Definition with SSM Secrets
resource "aws_ecs_task_definition" "this" {
  family                   = var.service_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  cpu    = "256"
  memory = "512"

  container_definitions = jsonencode([
    {
      name      = "nginx"
      image     = var.container_image
      cpu       = 256
      memory    = 512
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      # SSM Secrets injected at runtime - NO SECRET VALUES IN CODE
      secrets = [
        for i, param in var.ssm_parameter_names : {
          name      = upper(replace(basename(param), "/[^A-Za-z0-9_]/", "_"))
          valueFrom = startswith(param, "arn:aws:ssm:") ? param : param
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}${var.health_check_path} || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  tags = merge(var.tags, {
    Name = "${var.service_name}-task-definition"
  })
}

# ECS Service with Zero-Downtime Deployment
resource "aws_ecs_service" "this" {
  name            = var.service_name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "EC2"

  # Capacity Provider Strategy
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 100
    base              = 1
  }

  # Zero-Downtime Deployment Settings
  deployment_controller {
    type = "ECS"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 50

  # Spread tasks across AZs
  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "instanceId"
  }

  enable_execute_command     = true
  enable_ecs_managed_tags   = true
  propagate_tags            = "SERVICE"
  scheduling_strategy       = "REPLICA"

  health_check_grace_period_seconds = 60

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "nginx"
    container_port   = var.container_port
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [
      desired_count
    ]
  }

  depends_on = [
    aws_lb_listener.http,
    aws_lb_target_group.main,
    aws_ecs_cluster_capacity_providers.this,
    aws_autoscaling_group.ecs
  ]

  tags = merge(var.tags, {
    Name = "${var.service_name}-service"
  })
}