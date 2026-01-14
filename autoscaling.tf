# Launch template for ECS instances - NO PUBLIC IPs
resource "aws_launch_template" "ecs_instance" {
  name_prefix   = "${var.service_name}-ecs-instance-"
  image_id      = data.aws_ami.ecs_optimized.id
  instance_type = "t3.medium"
  key_name      = null # No SSH key - instances are not directly accessible

  iam_instance_profile {
    arn = aws_iam_instance_profile.ecs_instance_profile.arn
  }

  # CRITICAL: No public IPs
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = concat([aws_security_group.ecs_instances.id], var.existing_security_group_ids)
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 30
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.this.name} >> /etc/ecs/ecs.config
    echo ECS_ENABLE_CONTAINER_METADATA=true >> /etc/ecs/ecs.config
    echo ECS_ENABLE_SPOT_INSTANCE_DRAINING=true >> /etc/ecs/ecs.config
    echo ECS_ENABLE_TASK_IAM_ROLE=true >> /etc/ecs/ecs.config
    echo ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true >> /etc/ecs/ecs.config
  EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = merge(var.tags, {
      Name = "${var.service_name}-ecs-instance"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Group with Mixed Instances (On-Demand baseline + Spot overflow)
resource "aws_autoscaling_group" "ecs" {
  name_prefix         = "${var.service_name}-asg-"
  vpc_zone_identifier = var.private_subnet_ids
  min_size            = var.on_demand_base_capacity
  max_size            = var.max_capacity * 2 # Allow for task scaling overhead
  desired_capacity    = var.on_demand_base_capacity

  # Mixed Instances Policy: On-Demand baseline + Spot overflow
  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = var.on_demand_base_capacity
      on_demand_percentage_above_base_capacity = var.on_demand_percentage_above_base
      spot_allocation_strategy                 = "capacity-optimized"
      spot_instance_pools                      = 4
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.ecs_instance.id
        version            = "$Latest"
      }

      override {
        instance_type = "t3.medium"
      }

      override {
        instance_type = "t3a.medium"
      }

      override {
        instance_type = "m5.large"
      }

      override {
        instance_type = "m5a.large"
      }
    }
  }

  # Required for ECS capacity provider
  protect_from_scale_in = false

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = "${var.service_name}-ecs-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      desired_capacity # Managed by ECS capacity provider
    ]
  }
}