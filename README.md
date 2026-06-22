# KWU AWS AUTO INFRA

Interactive Bash automation for a highly available AWS 3-Tier sample environment in `ap-northeast-2`.

## Architecture

```text
Internet
  │
Route 53 → Application Load Balancer
              │
              ├─ Nginx 2A (public subnet) ─┐
              └─ Nginx 2C (public subnet) ─┼─→ Tomcat 2A / 2C (private subnets)
                                             │
                                             └─→ RDS MySQL (private DB subnets)

Admin PC → Bastion (public subnet) → Nginx / Tomcat via SSH
```

The script creates the VPC, subnets, Internet Gateway, NAT Gateway, security groups, Bastion, Nginx, Tomcat, RDS MySQL, ALB, target group, and Route 53 alias record. Nginx proxies `/app/` to Tomcat, where a small JSP page is deployed automatically.

## Prerequisites

- AWS CLI configured with credentials that can create and delete the listed AWS resources.
- A public Route 53 hosted zone for the domain entered at runtime.
- An EC2 key pair named `kwuaws` in `ap-northeast-2`.
- The AMI configured in `auto_infra_aio.sh` must be available in the selected region.
- Bash, `curl`, and `base64`.

The script defaults to `ap-northeast-2`. Its AMI and key-pair name are declared near the top of `auto_infra_aio.sh` if your environment differs.

## CloudShell usage

```bash
git clone <YOUR_GITHUB_REPOSITORY_URL>
cd aws-auto-infra
chmod +x auto_infra_aio.sh
ADMIN_CIDR=<YOUR_PUBLIC_IP>/32 ./auto_infra_aio.sh
```

Use menu option `1` to create the environment, `2` to delete it, and `3` to test the ALB and Tomcat proxy endpoint.

`ADMIN_CIDR` controls SSH access to Bastion. Do not leave it open to the internet in a real environment. For example:

```bash
ADMIN_CIDR=203.0.113.10/32 ./auto_infra_aio.sh
```

## After deployment

The final **Deployment Summary** prints:

- Bastion public IP
- ALB URL
- Route 53 domain URL
- Tomcat sample application URL at `http://<domain>/app/`
- Private RDS endpoint

Connect to the private instances through Bastion using the same EC2 key pair. Tomcat port `8080` is reachable only from the Nginx security groups; MySQL port `3306` is reachable only from Tomcat.

## Security and data handling

- RDS is private and uses an AWS-managed master password in Secrets Manager. The password is not printed or copied to EC2 user-data.
- The current JSP verifies the Nginx → Tomcat path and shows the configured DB endpoint. It does not issue SQL queries because the Tomcat instances are not granted Secrets Manager access.
- To add database-backed application behavior, give the Tomcat instance profile least-privilege access to the specific RDS-managed secret and retrieve it at application runtime.

## Cost and deletion

This deployment creates billable services, including a NAT Gateway, Application Load Balancer, EC2 instances, and RDS MySQL. Delete the environment with menu option `2` when it is no longer needed.

The deletion workflow removes the RDS instance with `--skip-final-snapshot`; back up any required data before deletion.

## License

This project is licensed under the [MIT License](LICENSE).
