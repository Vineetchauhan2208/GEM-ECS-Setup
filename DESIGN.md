# Production ECS on EC2 Design

## Architecture Overview

This design implements a production-grade ECS cluster on EC2 with zero-downtime deployments, secure secrets management, and cost-optimized capacity using mixed instances (On-Demand + Spot).

## Key Design Decisions

### A) Zero-Downtime Deployments

**Deployment Settings:**
- `deployment_maximum_percent = 200%`: Allows double the desired count during deployment
- `deployment_minimum_healthy_percent = 50%`: Ensures minimum 50% capacity remains healthy
- `health_check_grace_period_seconds = 60`: Gives tasks time to start before health checks
- `deployment_circuit_breaker`: Enabled with rollback for automatic failure recovery

**ALB Integration:**
- ALB health checks (`/health` endpoint) determine task readiness
- Connection draining handled by ALB target group deregistration delay
- Target group stickiness for session persistence
- Tasks deregister from ALB before termination during deployments

**Process Flow:**
1. New tasks start with updated task definition
2. Tasks pass health checks (port + HTTP health endpoint)
3. ALB shifts traffic to healthy new tasks
4. Old tasks stop receiving traffic
5. Old tasks enter STOPPING state with `deregistration_delay`
6. Tasks are terminated after draining completes

**Failure Protection:**
- If new tasks fail health checks, deployment stops
- Circuit breaker rolls back if >50% failure rate
- ALB continues routing to existing healthy tasks

### B) Secure Secrets Management

**SSM Parameter Store Integration:**
- Secrets referenced by ARN/name in task definition
- Injected as environment variables at container runtime
- No secrets stored in Terraform state, variables, or repository

**IAM Least Privilege:**
1. Task execution role has assume role policy for `ecs-tasks.amazonaws.com`
2. Custom inline policy grants `ssm:GetParameters` only on specific parameter ARNs
3. No administrative permissions granted
4. Instance role limited to ECS agent requirements

**Security Boundaries:**
- Secrets never exposed to Terraform
- Parameter names passed as variables (not values)
- KMS encryption for SSM parameters (assumed existing)
- No secret leakage in logs or metrics

### C) Spot Instance Strategy

**Capacity Mix:**
- `on_demand_base_capacity = 1`: Minimum On-Demand instances for baseline
- `on_demand_percentage_above_base = 20%`: 80% Spot, 20% On-Demand for scale-out
- `spot_allocation_strategy = "capacity-optimized"`: Chooses pools with most capacity

**Interruption Handling:**
1. ECS task draining on spot interruption notice (2-minute warning)
2. Managed termination protection prevents scale-in during deployments
3. Capacity provider launches replacement instances
4. ASG mixed instances policy selects optimal instance types

**Why No Downtime:**
- Tasks distributed across AZs and instance types
- On-Demand baseline ensures minimum capacity
- ECS reschedules tasks from interrupted Spot instances
- ALB health checks detect and reroute from unhealthy tasks

### D) Scaling Architecture

**Three-Level Scaling:**

1. **Service Scaling:** ECS Service Auto Scaling based on CPU/Memory
   - Not implemented due to time constraints
   - Would use CloudWatch metrics and Application Auto Scaling

2. **Cluster Capacity Scaling:** ECS Capacity Provider managed scaling
   - `target_capacity = 100`: Maintains buffer for pending tasks
   - Monitors `MemoryReservation` and `CPUReservation`
   - Scales ASG before tasks enter PENDING state

3. **Pending Task Handling:**
   - Capacity provider detects pending tasks
   - Triggers ASG scale-out via managed scaling
   - Uses mixed instances for fastest capacity acquisition
   - Prevents deadlock through capacity buffer

**Anti-Deadlock Mechanisms:**
- Capacity buffer (target_capacity < 100%)
- Mixed instances across AZs and types
- Managed scaling proactive capacity management

### E) Operational Excellence

**Top 5 Monitors & Alerts (3am Paging):**

1. **Service Unhealthy Tasks > 10%** (Critical)
   - Metric: `ECS/Service/HealthyTaskCount`
   - Threshold: <90% healthy for 5 minutes
   - Action: Auto-rollback + alert

2. **Cluster Capacity Insufficient** (Critical)
   - Metric: `ECS/Cluster/MemoryReservation`
   - Threshold: >90% for 10 minutes
   - Action: Manual scale-out investigation

3. **Spot Interruption Rate Spike** (Warning)
   - Metric: `AWS/EC2/SpotInterruptionRate`
   - Threshold: >30% increase hour-over-hour
   - Action: Review instance types/AZs

4. **Deployment Failure** (Critical)
   - Metric: `ECS/Service/DeploymentRollbacks`
   - Threshold: >0 in 1 hour
   - Action: Stop deployments, investigate

5. **Secrets Access Failure** (Critical)
   - Metric: `SSM/GetParameterErrors`
   - CloudTrail event pattern matching
   - Action: Immediate rollback to last working version

**Cost Optimization:**
- Spot instances for 80%+ of variable capacity
- Rightsized instance types (t3.medium baseline)
- GP3 volumes for better price/performance
- Managed scaling prevents over-provisioning
- Container insights for resource optimization

## Failure Mode Handling

### 1. AZ Failure
- Tasks spread across AZs via placement strategy
- ASG instances in multiple AZs
- ALB distributes across healthy AZs
- Capacity provider scales in other AZs

### 2. ECS Agent Failure
- ASG health checks terminate unhealthy instances
- Capacity provider replaces capacity
- Tasks rescheduled to healthy instances

### 3. SSM Parameter Store Outage
- Tasks fail to start (cannot fetch secrets)
- Deployment circuit breaker triggers rollback
- Existing tasks continue running with cached secrets
- Fallback to last working version

## Tradeoffs

1. **Cost vs. Availability:** 20% On-Demand ensures baseline but increases cost
2. **Speed vs. Safety:** Rolling updates (not blue/green) faster but riskier
3. **Simplicity vs. Features:** No custom metrics scaling due to time constraints
4. **Security vs. Usability:** No SSH access to instances (debugging harder)

## Production Recommendations

1. **Add:** Blue/Green deployments with CodeDeploy
2. **Add:** Custom metrics scaling (RPS, latency)
3. **Add:** Service mesh for advanced traffic management
4. **Add:** Canary analysis deployment strategy
5. **Add:** Disaster recovery across regions
