terraform {
  backend "s3" {
    bucket       = "maria-arpitha-tf-state-three-tier"
    key          = "ecs-fargate-lab/infra/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}