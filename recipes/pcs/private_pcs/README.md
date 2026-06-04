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

### Main Infrastructure Stack
- [`pcs-private-networking.yaml`](assets/pcs-private-networking.yaml) - Main template that orchestrates the deployment of VPC, subnets, and security groups via nested stacks:
  - [`pcs-private-vpc.yaml`](assets/pcs-private-vpc.yaml) - VPC and private subnets (no Internet Gateway or NAT Gateway)
  - [`pcs-private-sgs.yaml`](assets/pcs-private-sgs.yaml) - EFA-enabled security groups for cluster nodes and storage

### Optional Storage Stacks (Deploy independently after main stack)
- [`pcs-private-efs.yaml`](assets/pcs-private-efs.yaml) - Amazon EFS file system with mount targets
- [`pcs-private-fsxl.yaml`](assets/pcs-private-fsxl.yaml) - Amazon FSx for Lustre high-performance file system
- [`pcs-private-fsxn.yaml`](assets/pcs-private-fsxn.yaml) - Amazon FSx for NetApp ONTAP multi-protocol file system

## Usage

### Step 1: Deploy Main Infrastructure

Deploy the `pcs-private-networking.yaml` template to create the VPC, subnets, and security groups:

1. Open the AWS CloudFormation console in your target region.
2. Create a new stack using [`pcs-private-networking.yaml`](assets/pcs-private-networking.yaml).
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

### Step 2: Deploy Storage (Optional)

Deploy any of the storage stacks as needed. Each storage stack is independent and can be deployed in any order:

#### Deploy Amazon EFS (if CreateEFS was set to 'True' in Step 1)

1. Create a new CloudFormation stack using [`pcs-private-efs.yaml`](assets/pcs-private-efs.yaml).
2. Configure parameters:
   - **NetworkingStackName**: Name of the pcs-private-networking stack from Step 1
   - **SubnetIds**: Select all the private subnets from the dropdown (EFS will create a mount target in each)
   - **EFSPerformanceMode**: generalPurpose or maxIO
   - **EFSThroughputMode**: bursting or elastic
3. Review and create the stack.
4. After deployment, use the mount command from the stack outputs to mount EFS on your cluster nodes.

#### Deploy FSx for Lustre (if CreateFSxLustre was set to 'True' in Step 1)

1. Create a new CloudFormation stack using [`pcs-private-fsxl.yaml`](assets/pcs-private-fsxl.yaml).
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

1. Create a new CloudFormation stack using [`pcs-private-fsxn.yaml`](assets/pcs-private-fsxn.yaml).
2. Configure parameters:
   - **NetworkingStackName**: Name of the pcs-private-networking stack from Step 1
   - **SubnetId**: Select one of the private subnets from the dropdown
   - **FSxONTAPStorageCapacity**: Storage capacity in GiB (1024-196608)
   - **FSxONTAPThroughputCapacity**: Throughput in MB/s
   - **FSxONTAPDeploymentType**: SINGLE_AZ_1 or MULTI_AZ_1
   - **FSxONTAPVolumeSize**: Volume size in megabytes
3. Review and create the stack.
4. After deployment, use the mount command from the stack outputs to mount FSx ONTAP on your cluster nodes.

### Step 3: Create Your PCS Cluster

Use the VPC, subnets, and security groups created in Step 1 to configure your PCS cluster through the AWS PCS console or AWS CLI. Configure your cluster to use:
- The VPC and private subnets (from pcs-private-networking stack outputs)
- The cluster security groups (from pcs-private-networking stack outputs)
- VPC endpoints for AWS service access

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

- **No Internet Access**: Compute nodes have no internet connectivity. All software packages, container images, and dependencies must be:
  - Pre-installed in custom AMIs
  - Available through VPC endpoints (e.g., S3 Gateway Endpoint for accessing S3)
  - Accessible via on-premises connections (VPN/Direct Connect)
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
