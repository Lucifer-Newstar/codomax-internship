# IAM examples

All policies use **least privilege**: only the actions the component really needs, scoped to this
project's resources (names prefixed `cloudops-`, parameters under `/cloudops/`).

| File | Attached to | Purpose |
|---|---|---|
| `ec2-trust-policy.json` | role `cloudops-ec2-role` | lets the EC2 service assume the role (no keys on the VM) |
| `ec2-instance-policy.json` | role `cloudops-ec2-role` | read `/cloudops/<env>/*` SSM parameters, read the assets bucket, write CloudWatch logs/metrics |
| `developer-policy.json` | my IAM user / group `cloudops-developers` | everything the scripts in `../../scripts/` need, limited to one region and micro instance types |

`${AWS_REGION}`, `${AWS_ACCOUNT_ID}`, `${ENV_NAME}`, `${ASSET_BUCKET}` are filled in by
`scripts/iam_setup.sh` by `render_policy` (sed) before the policy is uploaded.

## Why roles, not access keys, on EC2

An instance role gives the VM short-lived credentials through the instance metadata service. There
is no key file to leak, nothing to rotate, and revoking access is one `detach-role-policy` away.
Long-lived access keys belong only on my laptop (for the CLI) and should be rotated regularly:

```bash
aws iam list-access-keys --user-name <me>                    # see key age
aws iam create-access-key --user-name <me>                   # make a new key
aws configure                                                # switch the CLI to it
aws iam update-access-key --user-name <me> --access-key-id <old> --status Inactive
aws iam delete-access-key --user-name <me> --access-key-id <old>   # after a few days with no issues
```

## Never the root account

The root account can delete everything and close the account. Use it once to create an admin IAM
user with MFA, then lock it away. `scripts/aws_preflight.sh` refuses to continue if it detects
root credentials (`arn:aws:iam::<id>:root`).
