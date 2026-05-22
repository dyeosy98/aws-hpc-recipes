# FlexLM License Sync for AWS PCS - Test Guide

This guide walks through deploying a test AWS PCS cluster, setting up the
license sync cron job, running the validation tests from the blog post,
and tearing everything down when you are done.

Region used throughout this guide: **us-east-1 (IAD)**

## Files in this repository

| File | Purpose |
|---|---|
| `pcs-test-cluster.yaml` | CloudFormation template that creates the VPC, PCS cluster (Slurm accounting + REST API enabled), login node group, and compute node group |
| `license-sync.sh` | Production sync script — polls real FlexLM via `lmstat` |
| `license-sync-mock.sh` | Test sync script — uses hardcoded values, no FlexLM server needed |
| `README.md` | This file |

The tests in Step 6 are split into two tracks:
- **Mock mode** (Tests 1–5): validates the full pipeline without a real FlexLM server
- **Live mode** (Test 6): connects to a real FlexLM server once mock tests pass

---

## Prerequisites

- AWS CLI installed and configured for us-east-1
- Permissions to create IAM roles, CloudFormation stacks, EC2, and PCS clusters
- Bash shell

---

## Step 1: Create an SSH key pair

```bash
aws ec2 create-key-pair \
  --region us-east-1 \
  --key-name pcs-test-key \
  --query "KeyMaterial" \
  --output text > pcs-test-key.pem

chmod 400 pcs-test-key.pem
```

Verify:

```bash
aws ec2 describe-key-pairs \
  --region us-east-1 \
  --key-names pcs-test-key \
  --query "KeyPairs[0].KeyName" \
  --output text
```

---

## Step 2: Deploy the PCS cluster stack

The cluster template enables two key features:

- `SlurmRest: Mode: STANDARD` — starts `slurmrestd` for operational visibility
- `Accounting: Mode: STANDARD` — starts managed `slurmdbd`, required for dynamic remote license resources

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --template-file pcs-test-cluster.yaml \
  --stack-name pcs-test-cluster \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      ClusterName=pcs-test \
      SlurmVersion=25.05 \
      KeyPairName=pcs-test-key \
      AvailabilityZone=us-east-1a \
      ClientIpCidr=0.0.0.0/0 \
      LoginNodeInstanceType=c6i.xlarge \
      ComputeNodeInstanceType=c6i.xlarge \
      MaxComputeNodes=4 \
      FlexlmServerName=flexlm-server
```

This takes 10 to 15 minutes. Wait for the cluster to become ACTIVE:

```bash
watch -n 30 "aws pcs get-cluster \
  --region us-east-1 \
  --cluster-identifier pcs-test \
  --query 'cluster.status' \
  --output text"
```

---

## Step 3: SSH into the login node

```bash
LOGIN_NODE_IP=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters \
    "Name=tag:Name,Values=pcs-test-login" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

ssh -i pcs-test-key.pem ec2-user@${LOGIN_NODE_IP}
```

---

## Step 4: Register license resources (one-time setup)

Run these commands on the login node. This registers the license resources
in `slurmdbd` so Slurm can track them dynamically.

```bash
SACCTMGR=/opt/aws/pcs/scheduler/slurm-25.05/bin/sacctmgr
SERVER=flexlm-server

sudo -u slurm $SACCTMGR -i add resource \
  name=comsol count=50 server=$SERVER \
  servertype=flexlm type=license \
  cluster=pcs-test allowed=100

sudo -u slurm $SACCTMGR -i add resource \
  name=ansys count=20 server=$SERVER \
  servertype=flexlm type=license \
  cluster=pcs-test allowed=100
```

Verify the resources are visible:

```bash
sudo -u slurm $SACCTMGR show resource withclusters
scontrol show lic
```

Expected: `comsol@flexlm-server` and `ansys@flexlm-server` with `Remote=yes`.

---

## Step 5: Deploy the sync script

From your local machine, copy both scripts to the login node:

```bash
scp -i pcs-test-key.pem license-sync.sh license-sync-mock.sh \
  ec2-user@${LOGIN_NODE_IP}:~/
```

On the login node, install them and set up the cron job using the mock script:

```bash
sudo cp ~/license-sync.sh /usr/local/bin/license-sync.sh
sudo cp ~/license-sync-mock.sh /usr/local/bin/license-sync-mock.sh
sudo chmod +x /usr/local/bin/license-sync.sh /usr/local/bin/license-sync-mock.sh

# Pre-create the log file with the right permissions for cron
sudo touch /var/log/license-sync.log
sudo chmod 666 /var/log/license-sync.log

sudo tee /etc/cron.d/license-sync <<EOF
LICENSE_FEATURES=comsol,ansys
FLEXLM_SERVER_NAME=flexlm-server
MOCK_COMSOL_ISSUED=50
MOCK_COMSOL_IN_USE=5
MOCK_ANSYS_ISSUED=20
MOCK_ANSYS_IN_USE=3
*/5 * * * * ec2-user /usr/local/bin/license-sync-mock.sh >> /var/log/license-sync.log 2>&1
$(echo)
EOF
```

You may want to add these files in your login node AMI image or in the userdata section of your launch template.

---

## Step 6: Test the pipeline

The tests below are split into two tracks. Run the mock tests first to
validate the full pipeline end-to-end. Once those pass, switch to live
mode if you have a real FlexLM server available.

---

### Mock mode tests (no FlexLM server required)

### Test 1: Run the sync script manually

On the login node:

```bash
LICENSE_FEATURES=comsol,ansys FLEXLM_SERVER_NAME=flexlm-server \
  /usr/local/bin/license-sync-mock.sh
```

Expected output (with no jobs running, all 5 COMSOL and 3 ANSYS in-use counts are external):

```
2026-03-12T09:00:00Z Starting license sync (MOCK mode)
comsol: mock issued=50 in_use=5 slurm_used=0 external=5 -> Total=45
Updated comsol: Total=45
ansys: mock issued=20 in_use=3 slurm_used=0 external=3 -> Total=17
Updated ansys: Total=17
2026-03-12T09:00:00Z License sync complete
```

Then verify Slurm reflects the counts:

```bash
scontrol show lic
```

Expected: `comsol@flexlm-server Total=45`, `ansys@flexlm-server Total=17`.

### Test 2: Modify a count and verify instant update

```bash
SACCTMGR=/opt/aws/pcs/scheduler/slurm-25.05/bin/sacctmgr

# Set comsol to 42 (simulating fewer licenses available)
sudo -u slurm $SACCTMGR -i modify resource \
  name=comsol server=flexlm-server set count=42

scontrol show lic
```

Expected: `comsol@flexlm-server` shows `Total=42` immediately.

Reset back to 50:

```bash
sudo -u slurm $SACCTMGR -i modify resource \
  name=comsol server=flexlm-server set count=50
```

### Test 3: External checkout causes job to pend, release unblocks it

This test demonstrates the core value of the solution. It shows how the sync
script protects against over-scheduling when licenses are consumed outside Slurm.

First, reset the mock to 10 total licenses with none in use:

```bash
MOCK_COMSOL_ISSUED=10 MOCK_COMSOL_IN_USE=0 \
MOCK_ANSYS_ISSUED=20 MOCK_ANSYS_IN_USE=0 \
LICENSE_FEATURES=comsol,ansys FLEXLM_SERVER_NAME=flexlm-server \
/usr/local/bin/license-sync-mock.sh

scontrol show lic
```

Expected: `comsol@flexlm-server Total=10 Used=0 Free=10`

**Submit Job 1 requesting 5 licenses:**

```bash
JOB1=$(sbatch -p compute --licenses=comsol@flexlm-server:5 \
  --wrap="sleep 120 && echo done" | awk '{print $4}')
echo "Job 1: $JOB1"
sleep 5
scontrol show lic
```

Expected: `Total=10 Used=5 Free=5` — Job 1 is running, 5 licenses free.

**Simulate an external application consuming 2 more licenses, then sync:**

```bash
MOCK_COMSOL_ISSUED=10 MOCK_COMSOL_IN_USE=7 \
LICENSE_FEATURES=comsol,ansys FLEXLM_SERVER_NAME=flexlm-server \
/usr/local/bin/license-sync-mock.sh

scontrol show lic
```

Expected: `Total=8 Used=5 Free=3` — sync reduced Total to account for the 2
external checkouts. Only 3 licenses are now available for new jobs.

**Submit Job 2 requesting 5 licenses:**

```bash
JOB2=$(sbatch -p compute --licenses=comsol@flexlm-server:5 \
  --wrap="sleep 60 && echo done" | awk '{print $4}')
echo "Job 2: $JOB2"
sleep 3
squeue
```

Expected: Job 2 is in state `PD` (pending) — Slurm correctly refuses to
schedule it because only 3 licenses are free.

**Simulate the external application releasing its 2 licenses, then sync:**

```bash
MOCK_COMSOL_ISSUED=10 MOCK_COMSOL_IN_USE=5 \
LICENSE_FEATURES=comsol,ansys FLEXLM_SERVER_NAME=flexlm-server \
/usr/local/bin/license-sync-mock.sh

scontrol show lic
sleep 10
squeue
```

Expected: `Total=10 Used=5 Free=5` — external licenses released, Total restored.
Job 2 transitions from `PD` to `R` (running) because 5 licenses are now free.

### Test 4: Submit a job that requests a license

```bash
sbatch -p compute --licenses=comsol@flexlm-server:2 --wrap="sleep 30 && echo done"
```

While the job is running:

```bash
scontrol show lic
```

You should see `Used=2` on `comsol@flexlm-server`. After the job finishes, `Used` returns to 0.

### Test 5: Check cron is running

Wait for the next 5-minute boundary, then:

```bash
tail -f /var/log/license-sync.log
```

You should see the mock sync output with the `external` accounting line.

---

### Live mode test (real FlexLM server)

### Test 6: Switch to a real FlexLM server

Once the mock tests pass, update the cron job to point at your real FlexLM
server and disable the mock shim.

First, verify `lmstat` can reach your server from the login node:

```bash
# lmstat is part of the FlexLM client tools — install if not present
# On Amazon Linux 2: copy the lmstat binary from your license server or
# install the FlexLM utilities package from your vendor

lmstat -a -c 27000@your-license-server.example.com
```

Expected: output listing features with `Total of N licenses issued`.

If `lmstat` works, update `/etc/cron.d/license-sync` to use the production script:

```bash
sudo tee /etc/cron.d/license-sync <<'EOF'
LICENSE_SERVER=27000@your-license-server.example.com
LICENSE_FEATURES=comsol,ansys
FLEXLM_SERVER_NAME=flexlm-server
*/5 * * * * ec2-user /usr/local/bin/license-sync.sh >> /var/log/license-sync.log 2>&1
EOF
```

Run the sync manually to confirm it works end-to-end:

```bash
LICENSE_SERVER=27000@your-license-server.example.com \
LICENSE_FEATURES=comsol,ansys \
FLEXLM_SERVER_NAME=flexlm-server \
/usr/local/bin/license-sync.sh
```

Expected output:

```
2026-03-12T09:00:00Z Starting license sync (LIVE mode)
comsol: issued=50 in_use=5 slurm_used=0 external=5 -> Total=45
Updated comsol: Total=45
ansys: issued=20 in_use=3 slurm_used=0 external=3 -> Total=17
Updated ansys: Total=17
2026-03-12T09:00:00Z License sync complete
```

Then verify Slurm reflects the real counts:

```bash
scontrol show lic
```

**Note on security groups:** The login node needs outbound TCP access to
your FlexLM server on port 27000 and the vendor daemon port (COMSOL: 1718,
ANSYS: 2325). If the login node is in a private subnet, ensure the NAT
gateway or VPC routing allows this traffic to reach your license server
(on-premises via Direct Connect/VPN, or EC2 in the same VPC).

---

## Step 7: Tear everything down

Log out of the login node and run from your local machine.

### Delete the PCS cluster stack

Some AWS account-level services (e.g. GuardDuty) may create VPC endpoints
in the cluster VPC. These must be removed before the VPC can be deleted,
otherwise CloudFormation will fail with a dependency error. The script
below handles this automatically.

```bash
# Get the VPC ID before deleting the stack
VPC_ID=$(aws cloudformation describe-stacks \
  --region us-east-1 \
  --stack-name pcs-test-cluster \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" \
  --output text)

# Delete any VPC endpoints that other services may have created in our VPC
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --region us-east-1 \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "VpcEndpoints[].VpcEndpointId" \
    --output text)
  if [ -n "$ENDPOINTS" ] && [ "$ENDPOINTS" != "None" ]; then
    echo "Deleting VPC endpoints: $ENDPOINTS"
    aws ec2 delete-vpc-endpoints \
      --region us-east-1 \
      --vpc-endpoint-ids $ENDPOINTS
    echo "Waiting 30s for endpoint ENIs to detach..."
    sleep 30
  fi
fi

# Now delete the stack
aws cloudformation delete-stack \
  --region us-east-1 \
  --stack-name pcs-test-cluster

# Poll until deleted (takes ~10 minutes — NAT gateway teardown is the slow part)
while true; do
  STATUS=$(aws cloudformation describe-stacks \
    --stack-name pcs-test-cluster \
    --query "Stacks[0].StackStatus" \
    --output text 2>&1)
  echo "$(date '+%H:%M:%S') $STATUS"
  [[ "$STATUS" == *"does not exist"* ]] && echo "Stack deleted." && break
  sleep 20
done
```

This deletes everything the stack created: the PCS cluster, VPC, NAT
gateway, login and compute node groups, IAM roles, and Lambda functions.
PCS also automatically deletes the JWT signing key from Secrets Manager
when the cluster is removed — no manual cleanup needed there.

### Delete the SSH key pair

```bash
aws ec2 delete-key-pair \
  --region us-east-1 \
  --key-name pcs-test-key

rm -f pcs-test-key.pem

echo "Key pair deleted."
```

### Verify nothing is left

```bash
aws cloudformation list-stacks \
  --region us-east-1 \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?contains(StackName,'pcs-test')].StackName"

aws pcs list-clusters \
  --region us-east-1 \
  --query "clusters[?name=='pcs-test'].name"
```

Both should return empty arrays.

---

## Cost estimate for a short test session

| Resource | Approximate cost |
|---|---|
| NAT Gateway | $0.045/hr + $0.045/GB data processed |
| c6i.xlarge login node (always on) | $0.204/hr |
| PCS controller (managed by AWS) | Included in PCS pricing |
| c6i.xlarge compute nodes | $0.204/hr per node, only while jobs run |

A typical half-day test session (4 hours) costs roughly $1.00 to $1.20,
dominated by the NAT Gateway and the login node.

---

## Troubleshooting

**sacctmgr: You are not running a supported accounting_storage plugin**

The cluster was not deployed with `Accounting: Mode: STANDARD`. Redeploy
the stack with the correct parameter. The cluster must be recreated — this
setting cannot be changed on an existing cluster without redeployment.

**sacctmgr: Access/permission denied**

You are running `sacctmgr` as `ec2-user` instead of the `slurm` user.
Always use `sudo -u slurm sacctmgr ...` or use the full path:
`sudo -u slurm /opt/aws/pcs/scheduler/slurm-25.05/bin/sacctmgr ...`

**scontrol show lic does not show remote licenses**

The resources may not have been registered yet. Run Step 4 (register
license resources) and verify with `sacctmgr show resource withclusters`.

**Login node is not reachable via SSH**

Check the login node security group allows inbound TCP 22 from your IP.
The stack defaults to `0.0.0.0/0` unless you specified a `ClientIpCidr`.

**Cluster stays in CREATING for more than 20 minutes**

Check the PCS cluster error info:

```bash
aws pcs get-cluster \
  --region us-east-1 \
  --cluster-identifier pcs-test \
  --query "cluster.errorInfo"
```

**Stack deletion fails with "subnet has dependencies" or "vpc has dependencies"**

Account-level services like GuardDuty can create VPC endpoints in your VPC
after the stack is deployed. These endpoints block subnet and VPC deletion.
The teardown script in Step 7 handles this automatically by removing VPC
endpoints before deleting the stack. If you hit this error manually, run:

```bash
VPC_ID=<your-vpc-id>
aws ec2 describe-vpc-endpoints \
  --region us-east-1 \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "VpcEndpoints[].VpcEndpointId" \
  --output text | xargs -r aws ec2 delete-vpc-endpoints \
  --region us-east-1 --vpc-endpoint-ids
```

Wait 30 seconds, then retry `aws cloudformation delete-stack`.
