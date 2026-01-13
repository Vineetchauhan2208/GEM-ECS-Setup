# Production Stress Test Responses

## 1) Spot Failure During Deployment

**Scenario:** During deployment, 60% of Spot instances are reclaimed.

**Impact Analysis:**

1. **Running Tasks on Spot Instances:**
   - Receive EC2 Spot interruption notice (2-minute warning)
   - ECS agent initiates task draining
   - Tasks enter `DRAINING` state
   - ALB stops sending new connections
   - Existing connections complete or timeout

2. **Pending Tasks:**
   - Capacity provider detects capacity loss
   - Triggers ASG to launch replacement instances
   - Uses On-Demand pool first (available capacity)
   - New tasks scheduled on replacement instances

3. **Capacity Provider Behavior:**
   - Detects `MemoryReservation` spike
   - Scales ASG to maintain `target_capacity`
   - Mixed instances policy selects available types
   - May increase On-Demand percentage temporarily

4. **ASG Response:**
   - Terminates interrupted instances
   - Launches replacements across AZs
   - Respects On-Demand/Spot distribution
   - May take 3-5 minutes for full recovery

5. **ALB & End Users:**
   - Existing connections to drained tasks complete
   - New connections route to healthy tasks
   - Possible increased latency during redistribution
   - No 5xx errors if minimum healthy percent maintained

**Why No Downtime:**
- `deployment_minimum_healthy_percent = 50%` ensures sufficient capacity
- Tasks spread across AZs and instance types
- On-Demand baseline absorbs initial shock
- ALB health checks reroute from unhealthy tasks
- Rolling deployment continues with available capacity

## 2) Secrets Break at Runtime

**Scenario:** SSM permission is removed from task role.

**Immediate Impact:**
1. **New Tasks:** Fail to start with "AccessDenied" error
2. **Existing Tasks:** Continue running (secrets already injected)
3. **ECS Service:** Deployment fails, circuit breaker triggers
4. **CloudWatch Logs:** Show IAM permission errors
5. **Metrics:** Increased `PendingTasks`, decreased `RunningTasks`

**Detection:**
- CloudWatch Alarm: `PendingTasks > 0 for 5 minutes`
- CloudTrail: `AccessDenied` events for `ssm:GetParameters`
- ECS Events: "failed to start task" with IAM error
- Deployment rollback triggered automatically

**Recovery Procedure:**
1. **Immediate:** Circuit breaker rolls back to last working version
2. **Investigation:** CloudTrail logs identify removed permissions
3. **Restoration:** Re-add IAM policy to task role
4. **Verification:** Manual deployment test
5. **Prevention:** IAM policy change approval process

**Secret Leak Prevention:**
- Secrets never logged (container env vars not in logs)
- No fallback mechanisms that could expose secrets
- Task role has only `GetParameters`, not `PutParameters`
- KMS encryption protects at-rest secrets

## 3) Pending Task Deadlock

**Scenario:** Service wants 10 tasks; cluster can run 6; 4 tasks PENDING.

**System State:**
- `RunningTasks = 6`, `PendingTasks = 4`, `DesiredTasks = 10`
- Cluster at 100% memory/CPU reservation
- Capacity provider `target_capacity = 100`

**Deadlock Prevention Mechanisms:**

1. **Capacity Provider Managed Scaling:**
   - Monitors `MemoryReservation` and `CPUReservation`
   - Should scale before reaching 100% reservation
   - `target_capacity = 100` means proactive scaling

2. **Pending Task Detection:**
   - ECS scheduler marks tasks as PENDING
   - Capacity provider receives scaling signal
   - ASG scale-out triggered within 1-2 minutes

3. **Why No Deadlock:**
   - Mixed instances policy can launch various types
   - Multiple AZs provide capacity options
   - On-Demand pool always available (slower, but available)
   - Managed scaling has buffer below 100%

**If Deadlock Occurs (Root Cause):**
1. **ASG at max size:** Increase `max_size` or optimize task size
2. **Insufficient capacity in region:** Use multiple instance families
3. **Rate limiting:** Implement gradual scale-out
4. **VPC limits:** Monitor and increase service quotas

**Resolution Steps:**
1. Increase ASG `max_size` temporarily
2. Review task resource allocations
3. Add more instance types to mixed policy
4. Consider Fargate for overflow capacity

## 4) Deployment Safety

**Rolling Deployment Timeline:**

1. **New Tasks Start:** Immediately when deployment begins
   - ECS scheduler places tasks respecting constraints
   - Tasks pull images, fetch secrets, initialize
   - Health checks begin after `health_check_grace_period`

2. **Old Tasks Stop Receiving Traffic:** After new tasks pass health checks
   - ALB health checks pass (HTTP 200 from `/health`)
   - Target group registers new tasks as healthy
   - ALB shifts traffic based on load balancing algorithm
   - Old tasks enter `DRAINING` state

3. **Old Tasks Killed:** After deregistration delay + connections complete
   - Default 300s deregistration delay allows graceful shutdown
   - Active connections complete or timeout
   - ECS stops task after draining completes
   - If tasks exceed `stopTimeout` (30s default), forced stop

**Health Check Failure Handling:**
- New tasks fail health checks repeatedly
- ALB marks as unhealthy, doesn't route traffic
- Deployment continues if `minimum_healthy_percent` maintained
- Circuit breaker triggers if >50% of new tasks fail
- Automatic rollback to previous version

## 5) TLS, Trust Boundary, Identity

**TLS Termination:**
- Location: Application Load Balancer (ALB)
- Certificate: ACM-managed certificate (assumed)
- Protocol: HTTPS listener on port 443
- Policy: ELBSecurityPolicy-TLS13-1-2-2021-06
- Internal: HTTP between ALB and tasks (within VPC)

**Container Identity:**
- AWS Identity: IAM Role attached to ECS Task
- Role Name: `[service-name]-task-execution-role`
- Assumed by: `ecs-tasks.amazonaws.com`
- Scope: Per-task, not per-container

**Resource Access:**
- SSM Parameter Store: Read-only for specific secrets
- CloudWatch Logs: Write access for container logs
- ECR: Pull access for container images
- No other AWS resource access by default

**Trust Boundaries:**
1. **Public Internet ↔ ALB:** TLS encrypted
2. **ALB ↔ ECS Tasks:** HTTP within VPC, security groups
3. **Tasks ↔ AWS Services:** IAM role permissions
4. **Tasks ↔ External Services:** Through NAT Gateway

## 6) Cost Floor

**With Zero Traffic for 12 Hours:**

**Still Paying For:**
1. **On-Demand Baseline:** 1 instance running 24/7
2. **EBS Volumes:** 30GB GP3 per instance
3. **ALB:** Hourly charge + LCU minimum
4. **NAT Gateway:** Hourly charge + data processing
5. **EIP:** Associated with NAT Gateway
6. **CloudWatch Logs:** Storage and ingestion
7. **ECS:** Cluster management (minimal)

**Estimated Minimum Cost:** ~$150-200/month

**Cost Reduction Strategies:**

1. **Scale to Zero Architecture:**
   - Replace with Fargate (no idle instances)
   - Use Lambda for API Gateway backend
   - Implement auto-scaling to zero with custom metric

2. **Optimize Baseline:**
   - Reduce `on_demand_base_capacity` to 0 in non-prod
   - Use smaller instance types (t3.micro for dev)
   - Implement scheduled scaling (office hours only)

3. **Infrastructure Changes:**
   - Replace NAT Gateway with VPC endpoints
   - Use shared ALB across services
   - Implement log retention policies (7 days vs 30)

4. **Without Sacrificing Safety:**
   - Maintain On-Demand baseline in production
   - Keep multi-AZ for availability
   - Maintain monitoring and alerting

## 7) Failure Modes

### Mode 1: ECS Agent Crash Loop

**Detection:**
- CloudWatch: `CPUUtilization = 0` but instance running
- ECS: No container metrics from instance
- ASG: Instance fails health checks

**Blast Radius:** Single instance, tasks rescheduled

**Mitigation:**
1. ASG terminates unhealthy instance
2. Capacity provider launches replacement
3. Tasks rescheduled to other instances
4. Root cause: Update ECS agent, instance AMI

### Mode 2: SSM Parameter Store Degraded

**Detection:**
- ECS: Tasks stuck in `PENDING`
- CloudTrail: `GetParameter` throttling/errors
- X-Ray: Increased latency to SSM

**Blast Radius:** All new deployments, scaling events

**Mitigation:**
1. Circuit breaker rolls back deployments
2. Existing tasks continue (cached secrets)
3. Implement secret caching layer in app
4. Fallback to encrypted environment variables

### Mode 3: ALB Target Group Health Check Storm

**Detection:**
- CloudWatch: Spiked `RequestCount` to `/health`
- ECS: Tasks CPU throttled by health checks
- Application: Increased latency for real traffic

**Blast Radius:** All tasks, potential cascading failure

**Mitigation:**
1. Adjust health check interval (30s → 60s)
2. Implement lightweight health endpoint
3. Use container-level health check instead
4. Add health check cache in application
