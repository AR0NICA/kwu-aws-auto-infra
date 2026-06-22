# KWU AWS AUTO INFRA

Terraform-managed AWS 3-Tier infrastructure for `ap-northeast-2`.

```text
Internet → Route 53 → ALB → Nginx (2 AZ) → Tomcat (2 AZ) → RDS MySQL
Admin PC → Bastion → Nginx / Tomcat
```

The stack uses one NAT Gateway and Single-AZ RDS to control cost. Nginx and Tomcat run across two Availability Zones. The ALB is the only public HTTP entry point; Tomcat and MySQL are private.

## Prerequisites

- Terraform 1.10 or later and AWS CLI authenticated for the target account.
- A public Route 53 hosted zone whose name exactly matches `domain_name`.
- Existing EC2 key pair `kwuaws` in `ap-northeast-2`, unless overridden in `terraform.tfvars`.
- The Ubuntu AMI configured in `variables.tf` must be available in `ap-northeast-2`.
- S3 bucket `kwu-prd-vpc-terraform-state` in `ap-northeast-2`, with versioning, default encryption, and public access block enabled.

The Terraform S3 backend is fixed to:

```text
bucket: kwu-prd-vpc-terraform-state
key:    kwu-prd-vpc/terraform.tfstate
region: ap-northeast-2
```

The deployment principal needs normal AWS resource permissions plus S3 `GetObject`, `PutObject`, `DeleteObject`, and `ListBucket` permissions for the state object and its `.tflock` lock file.

## First migration from the Bash stack

Do this before applying Terraform to the same domain.

1. Resolve the legacy Route 53 deletion failure by reading and deleting the exact current alias record. The first command is a safe dry-run.

   ```bash
   bash scripts/cleanup_legacy_route53_alias.sh \
     --hosted-zone-id <ROUTE53_HOSTED_ZONE_ID> \
     --record-name ar0nica.xyz

   bash scripts/cleanup_legacy_route53_alias.sh \
     --hosted-zone-id <ROUTE53_HOSTED_ZONE_ID> \
     --record-name ar0nica.xyz \
     --apply
   ```

2. Delete the remaining legacy AWS resources before switching to Terraform. Do not import the Bash-created stack into this repository.
3. Confirm that the old VPC, ALB, EC2 instances, RDS instance, and Route 53 A alias record are gone.

The legacy cleanup tool accepts only an A alias whose target ends in `elb.amazonaws.com.`. It sends the exact `ResourceRecordSet` returned by Route 53 in the DELETE request, which avoids the previous error caused by reconstructing a mismatched ALB alias payload.

## CloudShell usage

```bash
git clone https://github.com/AR0NICA/kwu-aws-auto-infra.git
cd kwu-aws-auto-infra
cp terraform.tfvars.example terraform.tfvars
```

Set your domain and public IP in `terraform.tfvars`, then provide the requested RDS password only for the active shell:

```bash
export TF_VAR_db_master_password='powerkwu'
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

`TF_VAR_db_master_password` is deliberately not written to a tracked file. Terraform marks it sensitive in CLI output, but it is still stored in the remote Terraform state. Restrict access to the backend bucket accordingly.

## Outputs and access

```bash
terraform output
```

Outputs include the Bastion public IP, ALB DNS name, website URL, Tomcat dashboard URL, and private RDS endpoint.

Connect to private instances through Bastion using the same EC2 key pair. The final app URL is:

```text
http://<domain_name>/app/
```

The Tomcat page is an automatically deployed visual status dashboard. It confirms the `ALB → Nginx → Tomcat` route and displays the private DB endpoint; it does not expose credentials or run SQL queries.

## Destroy

```bash
export TF_VAR_db_master_password='powerkwu'
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
```

Destroy deletes the Route 53 alias through Terraform state, then deletes the remaining infrastructure. RDS is configured with `skip_final_snapshot = true`; export any data you need before destruction. NAT Gateway, ALB, EC2, and RDS incur AWS charges while they exist.

## License

[MIT License](LICENSE)
