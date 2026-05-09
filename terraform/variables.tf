variable "aws_region" {
  description = "AWS region"
  default     = "ap-southeast-1"
}

variable "instance_type" {
  default = "t2.micro"
}

variable "key_name" {
  description = "Name of existing EC2 key pair for SSH"
  type        = string
  default     = "zoo-keypair"
}

variable "artifact_bucket_name" {
  description = "S3 bucket for artifacts (must be globally unique)"
  type        = string
  default     = "zoo-negara-artifacts-unique123"   # CHANGE to unique
}
