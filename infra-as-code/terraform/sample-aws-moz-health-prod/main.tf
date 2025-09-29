terraform {
  backend "s3" {
    bucket = "digit-mozhealthprd-terraform"
    key    = "digit-bootcamp-setup/terraform.tfstate"
    region = "af-south-1"
    # The below line is optional depending on whether you are using DynamoDB for state locking and consistency
    # dynamodb_table = "digit-mozhealthprd-terraform"
    # The below line is optional if your S3 bucket is encrypted
    encrypt = true
  }
}

module "network" {
  source             = "../modules/kubernetes/aws/network"
  vpc_cidr_block     = "${var.vpc_cidr_block}"
  cluster_name       = "${var.cluster_name}"
  availability_zones = "${var.network_availability_zones}"
}

# PostGres DB
module "db" {
  source                        = "../modules/db/aws"
  subnet_ids                    = "${module.network.private_subnets}"
  vpc_security_group_ids        = ["${module.network.rds_db_sg_id}"]
  availability_zone             = "${element(var.availability_zones, 0)}"
  instance_class                = "db.t3.micro"  ## postgres db instance type
  engine_version                = "12.22"   ## postgres version
  storage_type                  = "gp3"
  storage_gb                    = "350"     ## postgres disk size
  backup_retention_days         = "7"
  administrator_login           = "${var.db_username}"
  administrator_login_password  = "${var.db_password}"
  identifier                    = "${var.cluster_name}-db"
  db_name                       = "${var.db_name}"
  environment                   = "${var.cluster_name}"
}

data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}

data "tls_certificate" "thumb" {
  url = "${data.aws_eks_cluster.cluster.identity.0.oidc.0.issuer}"
}

provider "kubernetes" {
  host                   = "${data.aws_eks_cluster.cluster.endpoint}"
  cluster_ca_certificate = "${base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)}"
  token                  = "${data.aws_eks_cluster_auth.cluster.token}"
}

resource "aws_iam_role" "eks_iam" {
  name = "${var.cluster_name}-eks"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "EKSWorkerAssumeRole"
        Effect = "Allow",
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}"
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })
}

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 20.0"
  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version
  vpc_id          = module.network.vpc_id
  create_iam_role = false
  iam_role_arn    = "arn:aws:iam::564518252813:role/moz-health-prd2023071410543744360000000f"
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  authentication_mode = "API_AND_CONFIG_MAP"
  subnet_ids      = concat(module.network.private_subnets, module.network.public_subnets)
  node_security_group_additional_rules = {
    ingress_self_ephemeral = {
      description = "Node to node communication"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }
  cluster_addons = {
    vpc-cni = {
      most_recent              = true
      before_compute           = true
      configuration_values = jsonencode({
        env = {
          # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
          ENABLE_PREFIX_DELEGATION           = "true"
        }
      })
    }
  }
  cluster_timeouts = {
    create = "30m"
    delete = "15m"
    update = "60m"
  }
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
  tags = {
    "KubernetesCluster" = var.cluster_name
    "Name"              = var.cluster_name
  }
}

module "eks_managed_node_group" {
  # depends_on = [module.eks]
  version         = "~> 20.0"
  source = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  name            = "${var.cluster_name}"
  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version
  subnet_ids = slice(module.network.private_subnets, 0, length(var.availability_zones))
  vpc_security_group_ids  = [module.eks.node_security_group_id]
  cluster_service_cidr = module.eks.cluster_service_cidr
  use_custom_launch_template = true
  launch_template_name = "${var.cluster_name}-lt"
  block_device_mappings = {
    xvda = {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = 100
        volume_type           = "gp3"
        delete_on_termination = true
      }
    }
  }
  min_size     = var.min_worker_nodes
  max_size     = var.max_worker_nodes
  desired_size = var.desired_worker_nodes
  instance_types = var.instance_types
  capacity_type  = "ON_DEMAND"
  ebs_optimized  = "true"
  enable_monitoring = "true"
  # user_data_template_path = "user-data.yaml"
  iam_role_additional_policies = {
    CSI_DRIVER_POLICY = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    SQS_POLICY                   = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
  }
  labels = {
    Environment = var.cluster_name
  }
  tags = {
    "KubernetesCluster" = var.cluster_name
    "Name"              = var.cluster_name
  }
}

resource "kubernetes_annotations" "example" {
  api_version = "v1"
  kind        = "ServiceAccount"
  metadata {
    name = "ebs-csi-controller-sa"
    namespace = "kube-system"
  }
  annotations = {
    "eks.amazonaws.com/role-arn" = "${aws_iam_role.eks_iam.arn}"
  }
}

resource "kubernetes_annotations" "gp2_default" {
  annotations = {
    "storageclass.kubernetes.io/is-default-class" : "false"
  }
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }

  force = true
}

resource "kubernetes_storage_class" "ebs_csi_encrypted_gp3_storage_class" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" : "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    fsType    = "ext4"
    encrypted = true
    type      = "gp3"
  }

  depends_on = [kubernetes_annotations.gp2_default]
}


resource "aws_iam_role_policy_attachment" "cluster_AmazonEBSCSIDriverPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = "${aws_iam_role.eks_iam.name}"
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEC2FullAccess" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
  role       = "${aws_iam_role.eks_iam.name}"
}

#resource "aws_iam_openid_connect_provider" "eks_oidc_provider" {
#  client_id_list = ["sts.amazonaws.com"]
#  thumbprint_list = ["${data.tls_certificate.thumb.certificates.0.sha1_fingerprint}"] # This should be empty or provide certificate thumbprints if needed
#  url            = "${data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer}" # Replace with the OIDC URL from your EKS cluster details
#}

resource "aws_security_group_rule" "rds_db_ingress_workers" {
  description              = "Allow worker nodes to communicate with RDS database"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = module.network.rds_db_sg_id
  source_security_group_id = module.eks.node_security_group_id
  type                     = "ingress"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name      = data.aws_eks_cluster.cluster.name
  addon_name        = "kube-proxy"
  resolve_conflicts = "OVERWRITE"
}
resource "aws_eks_addon" "core_dns" {
  cluster_name      = data.aws_eks_cluster.cluster.name
  addon_name        = "coredns"
  resolve_conflicts = "OVERWRITE"
}
resource "aws_eks_addon" "aws_ebs_csi_driver" {
  cluster_name      = data.aws_eks_cluster.cluster.name
  addon_name        = "aws-ebs-csi-driver"
  # addon_version     = "v1.23.0-eksbuild.1"
  resolve_conflicts = "OVERWRITE"
}

module "es-master" {

  source = "../modules/storage/aws"
  storage_count = 3
  environment = "${var.cluster_name}"
  disk_prefix = "es-master"
  availability_zones = "${var.availability_zones}"
  storage_sku = "gp3"
  disk_size_gb = "10"

}


module "es-master-v8" {

  source = "../modules/storage/aws"
  storage_count = 3
  environment = "${var.cluster_name}"
  disk_prefix = "es-master-v8"
  availability_zones = "${var.availability_zones}"
  storage_sku = "gp3"
  disk_size_gb = "10"

}

module "es-data-v1" {

  source = "../modules/storage/aws"
  storage_count = 3
  environment = "${var.cluster_name}"
  disk_prefix = "es-data-v1"
  availability_zones = "${var.availability_zones}"
  storage_sku = "gp3"
  disk_size_gb = "100"

}

module "es-data-v8" {

  source = "../modules/storage/aws"
  storage_count = 3
  environment = "${var.cluster_name}"
  disk_prefix = "es-data-v8"
  availability_zones = "${var.availability_zones}"
  storage_sku = "gp3"
  disk_size_gb = "150"

}

module "zookeeper-infra" {

source = "../modules/storage/aws"
storage_count = 3
environment = "${var.cluster_name}"
disk_prefix = "zookeeper-infra"
availability_zones = "${var.availability_zones}"
storage_sku = "gp3"
disk_size_gb = "10"

}

module "kafka-infra" {
  source = "../modules/storage/aws"
  storage_count = 3
  environment = "${var.cluster_name}"
  disk_prefix = "kafka-infra"
  availability_zones = "${var.availability_zones}"
  storage_sku = "gp3"
  disk_size_gb = "100"

}

module "es-master-infra" {
  source = "../modules/storage/aws"
  storage_count = 3
  environment = "${var.cluster_name}"
  disk_prefix = "es-master-infra"
  availability_zones = "${var.availability_zones}"
  storage_sku = "gp3"
  disk_size_gb = "10"
}

module "es-data-infra-v1" {
  source = "../modules/storage/aws"
  storage_count = 3
  environment = "${var.cluster_name}"
  disk_prefix = "es-data-infra-v1"
  availability_zones = "${var.availability_zones}"
  storage_sku = "gp3"
  disk_size_gb = "100"
}

