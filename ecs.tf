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

# ECS Capacity Provider (attach ASG)
resource "aws_ecs_capacity_provider" "this" {
  name = "${var.service_name}-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs.arn

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 90
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 3
      instance_warmup_period    = 120
    }

    managed_termination_protection = "ENABLED"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.service_name}-capacity-provider"
  })
}

# Associate capacity provider with cluster
resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  capacity_providers = [
    aws_ecs_capacity_provider.this.name
  ]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 100
    base              = 1
  }

  depends_on = [aws_ecs_capacity_provider.this]
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

# ECS Task Definition (nginx:latest)
resource "aws_ecs_task_definition" "this" {
  family                   = "${var.service_name}-task"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "nginx"
      image     = "nginx:latest"
      essential = true
      cpu       = 256
      memory    = 512

      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]

      # SSM Parameter Store secrets injected at runtime
      secrets = [
        for secret in var.ssm_secret_params : {
          name      = upper(replace(basename(secret), "/[^A-Za-z0-9_]/", "_"))
          valueFrom = secret
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost/ || exit 1"]
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

# ECS Service (behind ALB) + Zero Downtime Deployment
resource "aws_ecs_service" "this" {
  name            = "${var.service_name}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "EC2"  # CRITICAL: Must specify EC2 launch type

  # Capacity Provider Strategy
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 100
    base              = 1
  }

  # Zero-downtime deployment settings
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  # Deployment circuit breaker for automatic rollback
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Spread tasks across AZs
  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "instanceId"
  }

  enable_execute_command = true
  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"
  scheduling_strategy     = "REPLICA"

  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks_sg.id]
    assign_public_ip = false  # CRITICAL: No public IPs
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "nginx"
    container_port   = 80
  }

  # Prevent recreation on task definition changes
  lifecycle {
    ignore_changes = [
      task_definition,
      desired_count
    ]
  }

  depends_on = [
    aws_lb_listener.http,
    aws_ecs_cluster_capacity_providers.this,
    aws_autoscaling_group.ecs
  ]

  tags = merge(var.tags, {
    Name = "${var.service_name}-service"
  })
}