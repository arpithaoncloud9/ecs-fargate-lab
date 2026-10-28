# Zero-Downtime Container Deployments on AWS ECS Fargate

A hands-on project where I containerized a Node.js web app, stored the image in Amazon ECR, and ran it on Amazon ECS Fargate behind an Application Load Balancer across two Availability Zones. I then tested real operational scenarios: self-healing, zero-downtime rolling updates, automatic rollback with the deployment circuit breaker, and manual rollback.

Everything was built **manually in the AWS console first**, so I understand what each component does and how they connect before automating it.

![Architecture](docs/architecture.png)

---

## Highlights

| Result | Evidence |
|---|---|
| Small, secure image | `myapp:v1` is 60.7 MB on Node 22 Alpine, runs as a non-root user, ECR scan: **0 vulnerabilities** |
| High availability | 2 Fargate tasks in **us-east-1a** and **us-east-1b** behind one ALB address |
| Self-healing | A stopped task was replaced automatically and re-registered in the target group |
| Zero-downtime release | Rolling update v1 → v2 completed in **2 min 42 s** with **zero failed requests** |
| Automatic rollback | A broken release (non-existent image tag) failed **3/3** tasks; the circuit breaker rolled back to the last good version while users only saw the working version |
| Manual rollback | Rolled back v2 → v1 by deploying an earlier task definition revision |

---

## Tech stack

- **App:** Node.js 22 (built-in `http` module, no dependencies)
- **Containers:** Docker, Docker Desktop
- **Registry:** Amazon ECR (private repository, scan on push)
- **Compute:** Amazon ECS on AWS Fargate (`awsvpc` networking)
- **Networking:** Application Load Balancer, target group, security groups, default VPC
- **Identity:** IAM task execution role, ECS service-linked role
- **Observability:** Amazon CloudWatch Logs (`awslogs` driver)
- **Source control:** GitHub

---

## Architecture

```
Developer ──docker build / push──▶ Amazon ECR (myapp:v1, scanned)
                                        │ pulled by execution role
                                        ▼
Users ──http:80──▶ ALB (alb-sg) ──▶ Target group (/health)
                                        ├──▶ Fargate task  us-east-1a :3000
                                        └──▶ Fargate task  us-east-1b :3000
                                               (myapp-task-sg: 3000 only from alb-sg)
                                                    │
                                                    └── logs ──▶ CloudWatch /ecs/myapp
```

**How a request flows:** users reach one fixed ALB DNS name on port 80. The listener forwards to the target group, which health-checks `/health` on each task every 10 seconds and only routes traffic to healthy tasks. Tasks accept traffic only from the ALB's security group.

---

## Repository structure

```
.
├── server.js          # Web server: page, /health endpoint, graceful shutdown
├── package.json       # Project metadata and start command
├── Dockerfile         # Node 22 Alpine image, non-root user
├── .dockerignore      # Keeps unneeded files out of the build context
├── docs/              # Architecture diagram and day-by-day notes
└── README.md
```

---

## The application

A small web page that makes ECS behavior visible:

| Shown on the page | Source | Why it's useful |
|---|---|---|
| Version | `APP_VERSION` env var | See which release is serving |
| Background color | `BG_COLOR` env var | Instantly see version changes |
| Task hostname | `os.hostname()` | See which task answered (load balancing) |
| Started at | Server start time | See when a task was replaced |
| Secret loaded | `API_KEY` env var present | Confirm secret injection (value never shown) |

Endpoints:
- `GET /` returns the HTML page.
- `GET /health` returns `200 ok` for ALB health checks (not logged, to keep logs clean).

The app handles **SIGTERM** by finishing in-flight requests before exiting, so ECS deployments and scale-in don't drop connections.

---

## Run locally

```bash
docker build --platform linux/amd64 -t myapp:v1 .
docker run --rm --platform linux/amd64 -p 3000:3000 myapp:v1
```

Open `http://localhost:3000` and `http://localhost:3000/health`.

Try configuration without rebuilding:

```bash
docker run --rm --platform linux/amd64 -p 3000:3000 \
  -e APP_VERSION=v2 -e BG_COLOR=#534ab7 myapp:v1
```

---

## Push to Amazon ECR

```bash
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

aws ecr create-repository --repository-name myapp \
  --image-scanning-configuration scanOnPush=true --region $REGION

aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $ECR

docker tag myapp:v1 $ECR/myapp:v1
docker push $ECR/myapp:v1
```

---

## What I built, day by day

### Day 1: Containerize the app and store it in ECR
- Wrote a Dockerfile on Node 22 Alpine running as the non-root `node` user.
- Built and tested `myapp:v1` locally, then pushed it to a private ECR repository with scan on push.
- **Learned:** Dockerfile → image → container, layers and caching, Docker's CLI/daemon architecture, ECR tags vs digests, manifests, and authentication.

![Day 1 flow: build, run, push to ECR](docs/day-1-docker-and-ecr.png)

<table>
  <tr>
    <td width="50%"><b>App running locally</b><br><img src="docs/screenshots/day1/local-app-running.png" alt="App running locally on port 3000"></td>
    <td width="50%"><b>Image pushed to ECR</b><br><img src="docs/screenshots/day1/ecr-image-pushed.png" alt="Image myapp:v1 in ECR"></td>
  </tr>
  <tr>
    <td colspan="2"><b>Scan on push: 0 vulnerabilities</b><br><img src="docs/screenshots/day1/ecr-scan-0-vulnerabilities.png" alt="ECR scan with 0 vulnerabilities"></td>
  </tr>
</table>

### Day 2: Run the app on ECS Fargate
| Resource | Purpose |
|---|---|
| Security group `myapp-task-sg` | Port 3000 access to tasks |
| Execution role `ecsTaskExecutionRole` | ECS pulls from ECR and writes logs |
| Service-linked role `AWSServiceRoleForECS` | ECS manages networking in the account |
| Log group `/ecs/myapp` | Application logs, 3-day retention |
| Cluster `learn-ecs` | Logical home for tasks and services |
| Task definition `myapp:1` | Image, 0.25 vCPU / 0.5 GB, port 3000, logs, role |

- Ran a **standalone task** (stayed down when stopped), then a **service** (replaced a stopped task automatically).
- **Learned:** task definition vs task vs service, `awsvpc` networking, execution role vs task role vs service-linked role, logging, and self-healing.

**Standalone task:** the task's public and private IPs match the page and hostname it serves.

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/day2/standalone-task-running.png" alt="Standalone task networking details"></td>
    <td width="50%"><img src="docs/screenshots/day2/standalone-task-webpage.png" alt="Page served by the standalone task"></td>
  </tr>
</table>

**Self-healing service:** after a task was stopped, the service started a replacement with a new IP and hostname.

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/day2/service-self-healing-events.png" alt="Service events showing the replacement task"></td>
    <td width="50%"><img src="docs/screenshots/day2/service-self-healing-webpage.png" alt="Page served by the replacement task"></td>
  </tr>
</table>

**Logs in CloudWatch:** one log stream per task, with the startup line and each request.

![CloudWatch logs](docs/screenshots/day2/cloudwatch-logs.png)

### Day 3: Load balancing and high availability
| Resource | Purpose |
|---|---|
| Security group `alb-sg` | HTTP 80 from the internet to the ALB |
| Rule on `myapp-task-sg` | Port 3000 **only from `alb-sg`** (security group chaining) |
| Target group `myapp-tg` | IP targets on port 3000, health check `/health` |
| ALB `myapp-alb` | Internet-facing in two AZs, listener 80 → `myapp-tg` |
| Service `myapp-web` | 2 tasks, one per AZ, auto-registered in the target group |

- Stopped a task under live traffic: the other task kept serving while ECS replaced it.
- **Learned:** listeners, target groups, target states (Initial, Healthy, Unused, Draining), multi-AZ design, and troubleshooting by layer (DNS → network → ALB → app).

**One ALB address, two tasks in two Availability Zones:**

![Page via ALB from two tasks](docs/screenshots/day3/page-via-alb.png)

<table>
  <tr>
    <td width="50%"><b>ALB active in two AZs</b><br><img src="docs/screenshots/day3/alb-active.png" alt="ALB active in us-east-1a and us-east-1b"></td>
    <td width="50%"><b>Target group: 2 healthy targets</b><br><img src="docs/screenshots/day3/target-group-2-healthy.png" alt="Target group with 2 healthy targets"></td>
  </tr>
</table>

### Day 4: Deployments and rollbacks
| Revision | Change | Outcome |
|---|---|---|
| `myapp:2` | `APP_VERSION=v2`, `BG_COLOR=#534ab7` | Rolling update, zero downtime |
| `myapp:3` | Image tag `:v99` (does not exist) | `CannotPullContainerError` ×3 → circuit breaker → automatic rollback to `myapp:2` |
| `myapp:1` | Manual rollback | Service returned to v1 with zero downtime |

```
Rolling update (min 100%, max 200%):
v1 v1 → v1 v1 + v2 v2 → v1 v1 (draining) + v2 v2 → v2 v2
```

- Verified each release with a request loop hitting the ALB every second, and with `aws ecs describe-services`.
- **Learned:** revisions are never overwritten (which makes rollback possible), rolling update vs circuit breaker, health checks as the release gate, and automatic vs manual rollback.

**Rolling update, live:** v1 and v2 served side by side, then only v2, with no failed requests.

<table>
  <tr>
    <td width="50%"><b>Request loop during the rollout</b><br><img src="docs/screenshots/day4/rolling-update-v1-v2-loop.png" alt="Request loop showing v1 and v2 mixed"></td>
    <td width="50%"><b>New v2 tasks registered and healthy</b><br><img src="docs/screenshots/day4/rolling-update-v2-registered-tg.png" alt="Target group with the two new v2 tasks healthy"></td>
  </tr>
</table>

![v2 live in both AZs](docs/screenshots/day4/rolling-update-v2-azs.png)

**Automatic rollback:** the broken release failed 3/3 tasks, the circuit breaker triggered, and ECS rolled back to v2.

![Circuit breaker triggered](docs/screenshots/day4/circuit-breaker-triggered.png)

**Manual rollback verified with the CLI:** `myapp:1`, 2 running, one PRIMARY deployment with COMPLETED rollout.

![Manual rollback CLI output](docs/screenshots/day4/manual-rollback-cli.png)

---

## Troubleshooting log

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot connect to the Docker daemon` | Docker Desktop not running | Started Docker Desktop |
| `EACCES: permission denied, open '/app/server.js'` | Non-root user couldn't read copied files | `COPY --chmod=644 package.json server.js ./` |
| `port is already allocated` | Old container still using port 3000 | `docker ps`, then `docker stop <id>` |
| `Unable to assume the service linked role` | First ECS use in the account | Created `AWSServiceRoleForECS` in IAM |
| `ERR_SSL_PROTOCOL_ERROR` | Browser used `https://` on an HTTP-only app | Used `http://` |
| `DNS_PROBE_FINISHED_NXDOMAIN` on the ALB | New ALB DNS name not yet propagated | Waited for the ALB to become Active |
| `503 Service Temporarily Unavailable` | Target group had no targets yet | Attached the ECS service to the target group |
| `CannotPullContainerError` (intentional) | Task definition referenced a missing tag | Circuit breaker rolled back automatically |

---

## Verify a deployment

```bash
aws ecs describe-services --cluster learn-ecs --services myapp-web \
  --query 'services[0].{taskDefinition:taskDefinition,running:runningCount,deployments:deployments[].{status:status,rollout:rolloutState,taskDef:taskDefinition}}' \
  --region us-east-1
```

A single deployment with `"status": "PRIMARY"` and `"rollout": "COMPLETED"` means the release is finished.

Watch which task and version answer, live:

```bash
while true; do curl -s -m 2 http://<alb-dns-name>/ | grep -oE 'ip-172-[0-9-]*|>v[0-9]<' | tr '\n' ' '; echo; sleep 1; done
```

---

## What I'd change for production

- Run tasks in **private subnets** with VPC endpoints (`ecr.api`, `ecr.dkr`, S3, `logs`) or a NAT gateway, with no public IPs.
- Add **HTTPS** on the ALB with an ACM certificate and redirect HTTP to HTTPS.
- Define all infrastructure in **Terraform**.
- Automate build, push, and deploy with **GitHub Actions using OIDC**, tagging images with the commit SHA.
- Add **service auto scaling**, **secrets from Secrets Manager**, and **CloudWatch alarms** on deployments.
- Enable **tag immutability** and **lifecycle policies** in ECR.

---

## Cost and cleanup

An ALB plus two small Fargate tasks costs roughly **$1–1.50 per day**. To pause, set the service's desired tasks to `0` (the ALB still bills while it exists). To clean up completely, delete in this order: ECS service → ALB → target group → cluster → security groups → ECR images and repository → log group.

---
---


# Production-Style ECS Fargate Infrastructure with Terraform

![Architecture](docs/screenshots/terraform/ecs_terraform_architecture.png)

This project builds a fully private, production-style ECS Fargate environment with Terraform. It replaces the manual console workflow from my earlier ECS lab with repeatable, secure infrastructure as code.

The whole stack (VPC, subnets, VPC endpoints, security groups, ECR, IAM, ECS cluster, task definition, service, and Application Load Balancer) is defined in code: **30 AWS resources**, created with `terraform apply` and removed with `terraform destroy`.

---

## Highlights

|Feature|Description|
|---|---|
|**Fully private compute**|Fargate tasks run in private subnets with **no public IPs**|
|**No NAT gateway**|Image pulls and logs go through **VPC endpoints** for ECR API, ECR Docker, S3, and CloudWatch Logs; tasks have no internet access at all|
|**Least-privilege networking**|Security group chaining: tasks accept port 3000 **only** from the ALB's security group|
|**Protected container registry**|ECR with **immutable tags**, scan on push, and a lifecycle policy|
|**High availability**|Two tasks across two Availability Zones behind one ALB DNS name|
|**Safe deployments (configured)**|Rolling updates (100% min / 200% max) with the deployment circuit breaker and automatic rollback|
|**Remote Terraform state**|S3 backend with S3-native locking, ready for CI/CD|

---

## Architecture

```
                    ┌──────────────────── Custom VPC 10.0.0.0/16 ─────────────────────┐
Users ──http:80──▶  │  PUBLIC SUBNETS (us-east-1a, us-east-1b)                         │
                    │     ALB (alb-sg: 80 from internet) ◀── internet gateway          │
                    │        │  listener :80 → target group (/health)                  │
                    │        ▼                                                         │
                    │  PRIVATE SUBNETS (us-east-1a, us-east-1b)                        │
                    │     Fargate task (10.0.11.x)   Fargate task (10.0.12.x)          │
                    │     task-sg: 3000 only from alb-sg · no public IP · no internet  │
                    │        │                                                         │
                    │     VPC endpoints: ecr.api · ecr.dkr · logs (interface)          │
                    │                    s3 (gateway, free)                            │
                    └────────┼─────────────────────────────────────────────────────────┘
                             ▼
                  ECR (image) · S3 (image layers) · CloudWatch Logs

Terraform state ──▶ S3 bucket (versioned, encrypted, locked)
```

**How a request flows:** the browser reaches the ALB in the public subnets on port 80. The listener forwards to the target group, which only routes to tasks passing the `/health` check. Tasks accept traffic only from the ALB's security group.

**How a task starts without internet access:** the execution role gets an ECR token through the `ecr.api` endpoint, reads the image manifest through `ecr.dkr`, downloads layers from S3 through the gateway endpoint, and sends logs through the `logs` endpoint. With private DNS enabled, the normal AWS hostnames resolve to these private endpoints, so ECS needs no special configuration.

---

## Design decisions

|Decision|Choice|Reason|
|---|---|---|
|Outbound access for private tasks|**VPC endpoints instead of a NAT gateway**|No internet path at all, and AWS traffic stays on the AWS network. Trade-off: the app can't call external APIs without adding a NAT gateway later|
|Terraform state|Existing S3 state bucket, with a **project-specific key** (`ecs-fargate-lab/infra/terraform.tfstate`)|One protected state bucket per account, separate keys per project|
|State locking|`use_lockfile = true`|S3-native locking (Terraform 1.10+), no DynamoDB table needed|
|Image tags|**Immutable**|A released version can never be overwritten, so every deployment traces back to an exact build|
|App version ownership|`ignore_changes = [task_definition]` on the service|Terraform owns the infrastructure; the upcoming CI/CD pipeline will own which app version runs|

---

## Resources created (30)

|Area|Resources|
|---|---|
|Network (12)|VPC, internet gateway, 2 public subnets, 2 private subnets, 2 route tables, 4 route table associations|
|VPC endpoints (5)|Endpoint security group, `ecr.api`, `ecr.dkr`, `logs` interface endpoints, S3 gateway endpoint|
|Security and registry (4)|ALB security group, task security group, ECR repository, ECR lifecycle policy|
|ECS foundation (5)|Task execution role, policy attachment, CloudWatch log group, ECS cluster, task definition|
|Traffic and service (4)|Application Load Balancer, target group, HTTP listener, ECS service|

---

## Repository structure

```
ecs-fargate-lab/
├── docs/
│   ├── architecture.png               # Architecture from the manual ECS lab
│   └── screenshots/
│       ├── day1/ ... day4/            # Manual ECS lab screenshots
│       └── terraform/                 # Screenshots for this Terraform build
│
├── terraform/
│   ├── .gitignore                     # Ignores .terraform/, *.tfstate, *.tfvars
│   └── infra/
│       ├── .terraform.lock.hcl        # Provider version lock (committed)
│       ├── versions.tf                # Terraform and AWS provider versions
│       ├── backend.tf                 # S3 remote state with locking
│       ├── providers.tf               # AWS provider, region, default tags
│       ├── variables.tf               # Region, names, CIDRs, port, task size, desired count
│       ├── network.tf                 # VPC, internet gateway, subnets, route tables
│       ├── endpoints.tf               # VPC endpoints and their security group
│       ├── security.tf                # ALB and task security groups
│       ├── ecr.tf                     # ECR repository and lifecycle policy
│       ├── iam.tf                     # ECS task execution role
│       ├── ecs.tf                     # Log group, cluster, task definition, service
│       ├── alb.tf                     # Load balancer, target group, listener
│       └── outputs.tf                 # VPC/subnet/SG IDs, ECR URL, cluster, app URL
│
├── Dockerfile                         # Node.js 22 Alpine, non-root user
├── server.js                          # Web page, /health endpoint, graceful shutdown
├── package.json
├── .dockerignore
├── .gitignore
├── LICENSE
└── README.md
```

---

## How to deploy

**Prerequisites:** Terraform 1.10+, AWS CLI with credentials, Docker, and an existing S3 bucket for state (set its name in `backend.tf`).

```bash
# 1. Create the infrastructure
cd terraform/infra
terraform init
terraform plan
terraform apply

# 2. Push the first image (one time; CI/CD will handle later images)
cd ../..
ECR=$(terraform -chdir=terraform/infra output -raw ecr_repository_url)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${ECR%/*}
docker build --platform linux/amd64 --provenance=false -t $ECR:v1 .
docker push $ECR:v1

# 3. Open the app
open $(terraform -chdir=terraform/infra output -raw app_url)
```

The ECS service starts as soon as the `v1` image is available in ECR.

---

## Screenshots

### 01 — All 30 resources managed by Terraform

`terraform state list` shows every resource in the project. `[0]` and `[1]` are resources created once per Availability Zone with `count`; `["ecr_api"]`, `["ecr_dkr"]`, and `["logs"]` are the VPC endpoints created with `for_each`.

![terraform state list](docs/screenshots/terraform/01_terraform_state_list.png)

### 02 — Custom VPC with public and private subnets

`myapp-vpc` (`10.0.0.0/16`) with 4 subnets across two AZs: public `10.0.1.0/24` and `10.0.2.0/24`, private `10.0.11.0/24` and `10.0.12.0/24`. Public subnets route to the internet gateway; private subnets have **no internet route**. The third route table, with no subnet associations, is the VPC's default main route table, which AWS creates automatically; it's unused.

![VPC resource map](docs/screenshots/terraform/02_vpc_resource_map.png)

### 03 — VPC endpoints instead of a NAT gateway

Four endpoints, all **Available**: `ecr.api` (login), `ecr.dkr` (image manifests), and `logs` (CloudWatch) as interface endpoints, plus S3 (image layers) as a free gateway endpoint.

![VPC endpoints](docs/screenshots/terraform/03_vpc_endpoints.png)

### 04 — Private ECR repository

Repository `myapp` with **immutable tags**, scan on push, and AES-256 encryption.

![ECR repository](docs/screenshots/terraform/04_ecr_repository.png)

### 05 — Internet-facing Application Load Balancer

`myapp-alb` is **Active** in the custom VPC, spanning the public subnets in **us-east-1a** and **us-east-1b**. Its DNS name is the single public address for the app.

![Application Load Balancer](docs/screenshots/terraform/05_alb.png)

### 06 — Target group: both tasks healthy

`myapp-tg` routes HTTP traffic to port 3000 on IP targets. Both tasks, **10.0.11.135** (us-east-1a) and **10.0.12.251** (us-east-1b), pass the `/health` check. ECS registered them automatically.

![Target group healthy](docs/screenshots/terraform/06_target_group_healthy.png)

### 07 — ECS service running

Service `myapp-web` in `myapp-cluster` is **Active** with **2 desired, 2 running**, deployment status **Success**, on task definition `myapp:4`. (Revision numbers never reset in a task definition family; revisions 1–3 were created during the earlier console lab.)

![ECS service running](docs/screenshots/terraform/07_ecs_service_running.png)

### 08 — Tasks have no public IP

Both tasks have **private IPs only** (`10.0.11.135`, `10.0.12.251`). They can't be reached from the internet; all traffic arrives through the ALB.

![Tasks with private IPs only](docs/screenshots/terraform/08_tasks_private_ip.png)

### 09 — App through the ALB

The same ALB address serves the page from two different tasks: `ip-10-0-11-135` in us-east-1a and `ip-10-0-12-251` in us-east-1b.

![App through the ALB](docs/screenshots/terraform/09_alb_browser.png)

### 10 — CloudWatch logs

Log group `/ecs/myapp` has one log stream per task (`ecs/myapp/<task-id>`). Logs reach CloudWatch through the **logs VPC endpoint**, since the tasks have no internet access.

![CloudWatch logs](docs/screenshots/terraform/10_cloudwatch_logs.png)

---

## Cost and cleanup

While running, this setup costs roughly **$2.50 per day** (3 interface endpoints, the ALB, and 2 small Fargate tasks). To remove everything:

```bash
cd terraform/infra
terraform destroy
```

The ECR repository uses `force_delete`, so it's removed along with its images. The state bucket isn't managed by this project, so it remains.

---

## What I learned

- Building infrastructure in **layers** (network → security → ECS → load balancing), with small, reviewable plans.
- **Remote state** design: one state bucket per account, separate keys per project, and S3-native locking.
- Running Fargate in **private subnets without NAT**: the four endpoints a task needs, and why VPC DNS settings matter.
- **NAT gateway vs VPC endpoints vs public IPs**: cost, security, and when each fits.
- Terraform features: `count`, `for_each`, `[*]`, `jsonencode`, `depends_on`, `lifecycle`, outputs, and default tags.
- Splitting ownership: Terraform for infrastructure, CI/CD for application versions.

---

## Author

**Maria Arpitha** · [GitHub](https://github.com/arpithaoncloud9)