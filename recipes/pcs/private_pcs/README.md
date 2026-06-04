# Building a Private PCS Cluster with No Internet Access

## Info

This recipe provides CloudFormation templates to create the networking and security prerequisites for deploying AWS Parallel Computing Service (PCS) clusters in fully isolated, internet-free environments.

References: 
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
- Optional security groups for shared storage (EFS, FSx for Lustre, FSx for NetApp ONTAP)
- PCS cluster within the fully-private VPC and optional shared storage

## Templates

- [`pcs-private-networking.yaml`](assets/pcs-private-networking.yaml) - Creates networking prerequisites (VPC, private subnets, VPC endpoints) for your PCS controller and compute nodes with no internet access.
- [`pcs-private-networking-sgs.yaml`](assets/pcs-private-networking-sgs.yaml) - Creates EFA-enabled security groups for PCS cluster nodes and optional security groups for shared storage systems.

## Usage

### Step 1: Deploy Private Networking

Deploy the `pcs-private-networking.yaml` template to create the isolated VPC infrastructure:

1. Open the AWS CloudFormation console in your target region.
2. Create a new stack using [`pcs-private-networking.yaml`](assets/pcs-private-networking.yaml).
3. Configure parameters:
   - **VpcCIDR**: CIDR block for the VPC (e.g., 10.0.0.0/16)
   - **NumberOfSubnets**: Number of private subnets to create (1, 2, or 3)
   - **Subnet1AZ/CIDR**: Availability Zone and CIDR for the first subnet
   - **Subnet2AZ/CIDR**: (Optional) Availability Zone and CIDR for the second subnet
   - **Subnet3AZ/CIDR**: (Optional) Availability Zone and CIDR for the third subnet
   - **CreateEFS**: Set to 'True' to create an EFS file system
   - **CreateFSxLustre**: Set to 'True' to create an FSx for Lustre file system
   - **CreateFSxONTAP**: Set to 'True' to create an FSx for NetApp ONTAP file system
   - **ClientIpCidr**: IP range allowed to SSH to login nodes (if using bastion access)
4. Review and create the stack.
5. After deployment, note the VPC ID and subnet IDs from the stack outputs.

### Step 2: Deploy Security Groups

Deploy the `pcs-private-networking-sgs.yaml` template to create security groups for cluster nodes and optional file systems:

1. Create a new CloudFormation stack using [`pcs-private-networking-sgs.yaml`](assets/pcs-private-networking-sgs.yaml).
2. Configure parameters:
   - **VpcId**: Use the VPC ID from Step 1
   - **StackName**: Parent stack name for resource naming
   - **ClientIpCidr**: IP range allowed to SSH to login nodes
   - **CreateEFS**: Set to 'True' if you created EFS in Step 1
   - **CreateFSxLustre**: Set to 'True' if you created FSx for Lustre in Step 1
   - **CreateFSxONTAP**: Set to 'True' if you created FSx for NetApp ONTAP in Step 1
3. Review and create the stack.
4. After deployment, note the security group IDs from the stack outputs.

### Step 3: Create Your PCS Cluster

Use the VPC, subnets, and security groups created in Steps 1-2 to configure your PCS cluster through the AWS PCS console or AWS CLI. Configure your cluster to use:
- The VPC and private subnets from Step 1
- The cluster security group from Step 2
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

## Cleaning Up

To delete the resources created by this recipe:

1. Delete your PCS cluster through the AWS PCS console or CLI.
2. Delete the CloudFormation stack created in Step 2 (security groups).
3. Delete the CloudFormation stack created in Step 1 (networking).
4. If you created any additional resources (bastion hosts, VPN connections, etc.), delete those as well.

## See Also

- [AWS PCS VPC and subnet requirements](https://docs.aws.amazon.com/pcs/latest/userguide/working-with_networking_vpc-requirements.html)
- [AWS PCS interface VPC endpoints (AWS PrivateLink)](https://docs.aws.amazon.com/pcs/latest/userguide/vpc-interface-endpoints.html)
- [AWS PCS security group requirements](https://docs.aws.amazon.com/pcs/latest/userguide/working-with_networking_sg.html)
