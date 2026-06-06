# Building a Private PCS Cluster with No Internet Access

## Info

This recipe provides CloudFormation templates to create the complete infrastructure for deploying AWS Parallel Computing Service (PCS) clusters in fully isolated, internet-free environments.

**References:** 
- [AWS PCS VPC and subnet requirements and considerations](https://docs.aws.amazon.com/pcs/latest/userguide/working-with_networking_vpc-requirements.html)
- [Access AWS Parallel Computing Service using an interface endpoint (AWS PrivateLink)](https://docs.aws.amazon.com/pcs/latest/userguide/vpc-interface-endpoints.html)
- [Amazon EFS Using VPC security groups](https://docs.aws.amazon.com/efs/latest/ug/network-access.html)
- [Amazon FSx for Lustre File system access control with Amazon VPC](https://docs.aws.amazon.com/fsx/latest/LustreGuide/limit-access-security-groups.html)
- [Amazon FSx for ONTAP File System Access Control with Amazon VPC](https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/limit-access-security-groups.html)
- [Get started with EFA and MPI for HPC workloads on Amazon EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start.html#efa-start-security)

This architecture is suitable for highly secure environments where compute nodes must not have any internet access. All AWS service communication happens through VPC endpoints (AWS PrivateLink).

## Architecture

The templates create:
- A fully private VPC with 1-3 subnets across user-selected Availability Zones
- No Internet Gateway or NAT Gateway (complete isolation)
- VPC endpoints for AWS PCS API access via PrivateLink
- EFA-enabled security groups for PCS cluster nodes
- Security groups for shared storage (EFS, FSx for Lustre, FSx for NetApp ONTAP)
- Optional independent shared storage stacks

## Templates

### Networking Stack
- [`pcs-private-networking.yaml`](assets/networking/pcs-private-networking.yaml) - Main template that orchestrates the deployment of VPC, subnets, and security groups via nested stacks:
  - [`pcs-private-vpc.yaml`](assets/networking/pcs-private-vpc.yaml) - VPC and private subnets (no Internet Gateway or NAT Gateway)
  - [`pcs-private-sgs.yaml`](assets/networking/pcs-private-sgs.yaml) - EFA-enabled security groups for cluster nodes and storage

### Storage Stacks (Optional, deploy independently)
- [`pcs-private-efs.yaml`](assets/storage/pcs-private-efs.yaml) - Amazon EFS file system with mount targets
- [`pcs-private-fsxl.yaml`](assets/storage/pcs-private-fsxl.yaml) - Amazon FSx for Lustre high-performance file system
- [`pcs-private-fsxn.yaml`](assets/storage/pcs-private-fsxn.yaml) - Amazon FSx for NetApp ONTAP multi-protocol file system

### Cluster Resources
- [`pcs-private-launch-template.yaml`](assets/cluster/pcs-private-launch-template.yaml) - EC2 Launch Templates with security groups and user data to mount EFS and FSx Lustre storage

## AMI Requirements

**IMPORTANT**: Before deploying the infrastructure, you must use AMIs with required software pre-installed. AWS PCS requires certain software components to be baked into the AMI rather than installed at boot time.

### Recommended: Use AWS PCS Sample AMIs

**AWS provides pre-built sample AMIs** with Slurm 24.11 and all required HPC software already installed. These AMIs are regularly updated and tested by AWS.

**To find AWS PCS sample AMIs**:
1. Go to the [AWS PCS AMI Release Notes](https://docs.aws.amazon.com/pcs/latest/userguide/ami-release-notes.html)
2. Look for AMIs with **Slurm version 24.11** (latest stable version)
3. Choose the AMI for your region and operating system:
   - Amazon Linux 2023 (recommended for new deployments)
   - Amazon Linux 2
   - RHEL 8/9
   - Ubuntu 20.04/22.04

**Sample AMI naming pattern**: `aws-pcs-sample-x86-64-slurm-24-11-*`

**What's pre-installed in AWS PCS sample AMIs**:
- ✅ Slurm 24.11 scheduler
- ✅ EFA drivers (Elastic Fabric Adapter)
- ✅ Lustre client (for FSx for Lustre)
- ✅ NFS utilities (for EFS and FSx ONTAP)
- ✅ HPC libraries (OpenMPI, Intel MPI)
- ✅ AWS ParallelCluster tools
- ✅ Common compilers and development tools

### Using AWS PCS Sample AMIs

When deploying the launch template (Step 3), use the AMI IDs from the AWS PCS sample AMIs:

```yaml
# Example AMI IDs (check AWS documentation for latest IDs in your region)
ComputeAmiId: ami-0xxxxxxxxxxxxx  # aws-pcs-sample-x86-64-slurm-24-11-al2023
LoginAmiId: ami-0xxxxxxxxxxxxx    # aws-pcs-sample-x86-64-slurm-24-11-al2023
```

### Why Use AWS PCS Sample AMIs?

- **Pre-configured**: All required software already installed and tested
- **Kernel compatibility**: EFA and Lustre modules built for the specific kernel
- **AWS maintained**: Regular updates and security patches
- **Best practices**: Configured according to AWS HPC recommendations
- **Time savings**: No need to build custom AMIs from scratch

### Customizing AWS PCS Sample AMIs (Optional)

If you need to add your own application software:

1. Launch an instance using an AWS PCS sample AMI
2. Install your additional software:
   ```bash
   # Your application-specific software
   sudo yum install -y your-application
   
   # Your custom MPI codes, libraries, etc.
   ```
3. Create a new AMI from this instance via EC2 console
4. Use your custom AMI ID in the launch template

This approach gives you AWS's tested base configuration plus your custom software.

## Usage

### Step 1: Deploy Networking Infrastructure

Deploy the `pcs-private-networking.yaml` template to create the VPC, subnets, and security groups:

1. Open the AWS CloudFormation console in your target region.
2. Create a new stack using [`pcs-private-networking.yaml`](assets/networking/pcs-private-networking.yaml).
3. Configure parameters:
   - **VpcCIDR**: CIDR block for the VPC (e.g., 10.0.0.0/16)
   - **NumberOfSubnets**: Number of private subnets to create (1, 2, or 3)
   - **Subnet1AZ/CIDR**: Availability Zone and CIDR for the first subnet
   - **Subnet2AZ/CIDR**: (Optional) Availability Zone and CIDR for the second subnet
   - **Subnet3AZ/CIDR**: (Optional) Availability Zone and CIDR for the third subnet
   - **CreateEFS**: Set to 'True' if you plan to deploy EFS (creates security group)
   - **CreateFSxLustre**: Set to 'True' if you plan to deploy FSx for Lustre (creates security group)
   - **CreateFSxONTAP**: Set to 'True' if you plan to deploy FSx for ONTAP (creates security group)
   - **ClientIpCidr**: IP range allowed to SSH to login nodes
   - **HpcRecipesS3Bucket**: S3 bucket containing the templates
   - **HpcRecipesBranch**: Branch/version of the templates
4. Review and create the stack.
5. After deployment, note the stack name - you'll need it for storage stacks.

### Step 2: Deploy Storage Infrastructure (Optional)

Deploy any of the storage stacks as needed. Each storage stack is independent and can be deployed in any order:

#### Deploy Amazon EFS (if CreateEFS was set to 'True' in Step 1)

1. Create a new CloudFormation stack using [`pcs-private-efs.yaml`](assets/storage/pcs-private-efs.yaml).
2. Configure parameters:
   - **NetworkingStackName**: Name of the pcs-private-networking stack from Step 1
   - **SubnetIds**: Select all the private subnets from the dropdown (EFS will create a mount target in each)
   - **EFSPerformanceMode**: generalPurpose or maxIO
   - **EFSThroughputMode**: bursting or elastic
3. Review and create the stack.
4. After deployment, use the mount command from the stack outputs to mount EFS on your cluster nodes.

#### Deploy FSx for Lustre (if CreateFSxLustre was set to 'True' in Step 1)

1. Create a new CloudFormation stack using [`pcs-private-fsxl.yaml`](assets/storage/pcs-private-fsxl.yaml).
2. Configure parameters:
   - **NetworkingStackName**: Name of the pcs-private-networking stack from Step 1
   - **SubnetId**: Select one of the private subnets from the dropdown
   - **FSxLustreStorageCapacity**: Storage capacity in GiB (minimum 1200, increments of 2400)
   - **FSxLustrePerUnitStorageThroughput**: Throughput in MB/s/TiB (125, 250, 500, or 1000)
   - **FSxLustreDataCompressionType**: Data compression (NONE or LZ4 for automatic compression)
3. Review and create the stack.
4. After deployment, use the mount command from the stack outputs to mount FSx Lustre on your cluster nodes.

**Note**: This template uses FSx for Lustre PERSISTENT_2 deployment type, which is available in most commercial AWS regions but may not be available in GovCloud regions.

#### Deploy FSx for NetApp ONTAP (if CreateFSxONTAP was set to 'True' in Step 1)

1. Create a new CloudFormation stack using [`pcs-private-fsxn.yaml`](assets/storage/pcs-private-fsxn.yaml).
2. Configure parameters:
   - **NetworkingStackName**: Name of the pcs-private-networking stack from Step 1
   - **SubnetId**: Select one of the private subnets from the dropdown
   - **FSxONTAPStorageCapacity**: Storage capacity in GiB (1024-196608)
   - **FSxONTAPThroughputCapacity**: Throughput in MB/s
   - **FSxONTAPDeploymentType**: SINGLE_AZ_1 or MULTI_AZ_1
   - **FSxONTAPVolumeSize**: Volume size in megabytes
3. Review and create the stack.
4. After deployment, use the mount command from the stack outputs to mount FSx ONTAP on your cluster nodes.

### Step 3: Create Launch Templates

Before creating the PCS cluster, deploy launch templates that configure security groups and mount storage on both compute and login nodes. This single stack creates **two launch templates**.

**Prerequisites**: You must have AMI IDs ready - use AWS PCS sample AMIs with Slurm 24.11 (see AMI Requirements section above).

1. Find the AWS PCS sample AMI IDs for your region from the [AWS PCS AMI Release Notes](https://docs.aws.amazon.com/pcs/latest/userguide/ami-release-notes.html)
2. Create a new CloudFormation stack using [`pcs-private-launch-template.yaml`](assets/cluster/pcs-private-launch-template.yaml).
3. Configure parameters:
   - **NetworkingStackName**: Name of the pcs-private-networking stack from Step 1
   - **OperatingSystem**: Select your OS (AmazonLinux2023 recommended) - must match your AMI
   
   **For Storage Configuration** (all optional):
   - **EFSStackName**: Name of the EFS stack if you deployed EFS
   - **EFSMountDirectory**: Mount point for EFS (e.g., /home)
   - **FSxLustreStackName**: Name of the FSx Lustre stack if you deployed FSx Lustre
   - **FSxLMountDirectory**: Mount point for FSx Lustre (e.g., /fsx)

   **For Login Node Configuration**:
   - **LoginInstanceType**: EC2 instance type for login nodes (e.g., c6i.8xlarge)
   - **LoginAmiId**: AWS PCS sample AMI ID for login nodes (e.g., `ami-0xxxxxxxxxxxxx`)
   
   **For Compute Node Configuration**:
   - **ComputeInstanceType**: EC2 instance type for compute nodes (e.g., c6i.32xlarge, hpc7a.96xlarge)
   - **ComputeAmiId**: AWS PCS sample AMI ID for compute nodes (e.g., `ami-0xxxxxxxxxxxxx`)
   
4. Review and create the stack.

**Key Differences Between Launch Templates**:

| Feature | Compute Node Template | Login Node Template |
|---------|----------------------|---------------------|
| Security Group | ComputeNodeSecurityGroupId | LoginNodeSecurityGroupId |
| Storage Mounting | ✅ Mounts EFS and FSx Lustre | ✅ Mounts EFS and FSx Lustre |
| Typical Instance Types | c6i.32xlarge, hpc7a.96xlarge | c6i.8xlarge, c6i.4xlarge |

**Operating System Support**:

The launch templates support multiple Linux distributions:
- Amazon Linux 2023
- Amazon Linux 2
- RHEL 8/9
- Ubuntu 20.04/22.04

The OperatingSystem parameter is primarily for documentation and reference. Since all required software must be pre-installed in your AMI, ensure your AMI matches the selected operating system.

**Note**: The launch templates include user data that:
- Verifies required software is installed (Lustre client if using FSx Lustre)
- Mounts configured storage at instance launch (EFS, FSx Lustre)
- Logs all setup activities to `/var/log/pcs-node-setup.log`
- **Does NOT install software** - all required software must be pre-installed in the AMI (use AWS PCS sample AMIs)

### Step 4: Create Your PCS Cluster

Use the VPC, subnets, security groups, and launch templates to configure your PCS cluster through the AWS PCS console or AWS CLI:

1. **Cluster Configuration**:
   - VPC and private subnets (from pcs-private-networking stack outputs)
   - Cluster security groups (from pcs-private-networking stack outputs)
   - VPC endpoints for AWS service access

2. **Compute Node Configuration**:
   - Use the compute launch template created in Step 3
   - Select appropriate instance types and counts

3. **Login Node Configuration** (Optional):
   - Use the login launch template created in Step 3
   - Configure access patterns (see Access Patterns section below)

Refer to the [AWS PCS User Guide](https://docs.aws.amazon.com/pcs/latest/userguide/getting-started.html) for detailed cluster creation instructions.

## Access Patterns

Since this is a private cluster with no internet access, you'll need one of these access patterns:

### Option 1: Bastion Host
Deploy a bastion host in a separate public subnet (or an existing VPC with internet access) and use it to SSH into login nodes.

### Option 2: AWS Systems Manager Session Manager
Use AWS Systems Manager Session Manager to establish sessions to login nodes without requiring a bastion host or direct internet connectivity.

### Option 3: VPN or Direct Connect
Connect through AWS Site-to-Site VPN or AWS Direct Connect from your on-premises network.

## Important Considerations

- **AWS PCS Sample AMIs**: Use AWS-provided sample AMIs with Slurm 24.11 (see AMI Requirements section). These AMIs include EFA drivers, Lustre client, NFS utilities, and HPC software pre-installed. The launch templates do NOT install software - they only mount storage.
- **No Internet Access**: Compute nodes have no internet connectivity. All software packages, container images, and dependencies must be:
  - Pre-installed in AMIs (use AWS PCS sample AMIs or customize them)
  - Available through VPC endpoints (e.g., S3 Gateway Endpoint for accessing S3)
  - Accessible via on-premises connections (VPN/Direct Connect)
- **Kernel Module Software**: Software requiring kernel modules (EFA drivers, Lustre client) cannot be installed via user data at boot time. They must be pre-installed in the AMI with modules compiled for the running kernel. AWS PCS sample AMIs include these pre-compiled.
- **VPC Endpoints**: The template creates VPC endpoints for AWS PCS API access. You may need additional endpoints for other AWS services (S3, ECR, CloudWatch, etc.).
- **DNS Resolution**: The VPC has DNS hostnames enabled to support VPC endpoint DNS resolution.
- **Security Groups**: Follow AWS PCS security group requirements for proper Slurm communication between controller, compute nodes, and login nodes.
- **Storage Independence**: Storage stacks are independent and can be deployed, updated, or deleted without affecting the main infrastructure or other storage stacks.

## Cleaning Up

To delete the resources created by this recipe:

1. Delete your PCS cluster through the AWS PCS console or CLI.
2. Delete any storage stacks (pcs-private-efs, pcs-private-fsxl, pcs-private-fsxn) that you deployed.
3. Delete the main infrastructure stack (pcs-private-networking).
4. If you created any additional resources (bastion hosts, VPN connections, etc.), delete those as well.

**Note**: Storage stacks must be deleted before the main pcs-private-networking stack, as they depend on the security groups and networking resources.

## See Also

- [AWS PCS VPC and subnet requirements](https://docs.aws.amazon.com/pcs/latest/userguide/working-with_networking_vpc-requirements.html)
- [AWS PCS interface VPC endpoints (AWS PrivateLink)](https://docs.aws.amazon.com/pcs/latest/userguide/vpc-interface-endpoints.html)
- [AWS PCS security group requirements](https://docs.aws.amazon.com/pcs/latest/userguide/working-with_networking_sg.html)
