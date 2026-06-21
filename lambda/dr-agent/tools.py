"""
DR Agent — AWS health-check and recovery tools.
All functions read resource identifiers from environment variables
injected by Terraform at Lambda deploy time.
"""

import os
import boto3
from botocore.exceptions import ClientError

# AWS_REGION is a reserved Lambda env var — we set AWS_REGION_NAME to avoid conflicts
_REGION = lambda: os.environ.get("AWS_REGION_NAME") or os.environ.get("AWS_REGION", "ap-south-1")


# ── Health checks ──────────────────────────────────────────────────────────────

def check_rds() -> dict:
    """Return status of the CloudKitchen RDS PostgreSQL instance."""
    db_id = os.environ.get("RDS_DB_IDENTIFIER", "")
    if not db_id:
        return {"status": "unknown", "note": "RDS_DB_IDENTIFIER not configured"}
    try:
        rds = boto3.client("rds", region_name=_REGION())
        resp = rds.describe_db_instances(DBInstanceIdentifier=db_id)
        inst = resp["DBInstances"][0]
        return {
            "status":         inst["DBInstanceStatus"],
            "engine":         inst["Engine"],
            "instance_class": inst["DBInstanceClass"],
            "multi_az":       inst["MultiAZ"],
            "storage_gb":     inst["AllocatedStorage"],
        }
    except ClientError as e:
        return {"status": "error", "error": e.response["Error"]["Message"]}


def check_alb_targets() -> dict:
    """Return healthy/unhealthy counts for every target group on the external ALB."""
    alb_arn = os.environ.get("ALB_ARN", "")
    if not alb_arn:
        return {"error": "ALB_ARN not configured"}

    # Map TG ARN → service metadata so the agent knows which ASG to scale
    tg_meta = {
        os.environ.get("MENU_TG_ARN",  ""): {"service": "menu",  "asg": os.environ.get("MENU_ASG_NAME",  "")},
        os.environ.get("ORDER_TG_ARN", ""): {"service": "order", "asg": os.environ.get("ORDER_ASG_NAME", "")},
        os.environ.get("AUTH_TG_ARN",  ""): {"service": "auth",  "asg": os.environ.get("AUTH_ASG_NAME",  "")},
        os.environ.get("AI_TG_ARN",    ""): {"service": "ai",    "asg": os.environ.get("AI_ASG_NAME",    "")},
    }

    try:
        elbv2 = boto3.client("elbv2", region_name=_REGION())
        tgs   = elbv2.describe_target_groups(LoadBalancerArn=alb_arn)["TargetGroups"]
        result = {}
        for tg in tgs:
            arn      = tg["TargetGroupArn"]
            targets  = elbv2.describe_target_health(TargetGroupArn=arn)["TargetHealthDescriptions"]
            healthy  = sum(1 for t in targets if t["TargetHealth"]["State"] == "healthy")
            meta     = tg_meta.get(arn, {"service": "unknown", "asg": ""})
            result[tg["TargetGroupName"]] = {
                "total":           len(targets),
                "healthy_count":   healthy,
                "unhealthy_count": len(targets) - healthy,
                "service":         meta["service"],
                "asg_name":        meta["asg"],
            }
        return result
    except ClientError as e:
        return {"error": e.response["Error"]["Message"]}


def check_asgs() -> dict:
    """Return in-service instance counts for all CloudKitchen ASGs."""
    names = [n for n in [
        os.environ.get("MENU_ASG_NAME",  ""),
        os.environ.get("ORDER_ASG_NAME", ""),
        os.environ.get("AUTH_ASG_NAME",  ""),
        os.environ.get("AI_ASG_NAME",    ""),
    ] if n]

    if not names:
        return {"error": "No ASG names configured"}

    try:
        asc  = boto3.client("autoscaling", region_name=_REGION())
        resp = asc.describe_auto_scaling_groups(AutoScalingGroupNames=names)
        result = {}
        for asg in resp["AutoScalingGroups"]:
            in_service = sum(
                1 for i in asg["Instances"]
                if i["LifecycleState"] == "InService" and i["HealthStatus"] == "Healthy"
            )
            result[asg["AutoScalingGroupName"]] = {
                "desired":    asg["DesiredCapacity"],
                "in_service": in_service,
                "min_size":   asg["MinSize"],
                "max_size":   asg["MaxSize"],
            }
        return result
    except ClientError as e:
        return {"error": e.response["Error"]["Message"]}


def check_dlq() -> dict:
    """Return approximate message count in the orders dead-letter queue."""
    url = os.environ.get("ORDERS_DLQ_URL", "")
    if not url:
        return {"depth": 0, "note": "ORDERS_DLQ_URL not configured"}
    try:
        sqs  = boto3.client("sqs", region_name=_REGION())
        attr = sqs.get_queue_attributes(
            QueueUrl=url,
            AttributeNames=["ApproximateNumberOfMessages"]
        )
        return {"depth": int(attr["Attributes"].get("ApproximateNumberOfMessages", 0))}
    except ClientError as e:
        return {"depth": 0, "error": e.response["Error"]["Message"]}


# ── Recovery actions ───────────────────────────────────────────────────────────

def scale_asg(asg_name: str, increment: int = 1) -> str:
    """Bump ASG desired capacity by increment (capped at max_size)."""
    if not asg_name:
        return "No ASG name provided"
    try:
        asc  = boto3.client("autoscaling", region_name=_REGION())
        resp = asc.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])
        if not resp["AutoScalingGroups"]:
            return f"ASG '{asg_name}' not found"

        asg         = resp["AutoScalingGroups"][0]
        current     = asg["DesiredCapacity"]
        new_desired = min(current + increment, asg["MaxSize"])

        if new_desired == current:
            return f"ASG '{asg_name}' is already at max capacity ({current})"

        asc.update_auto_scaling_group(AutoScalingGroupName=asg_name, DesiredCapacity=new_desired)
        return f"Scaled '{asg_name}': {current} → {new_desired}"
    except ClientError as e:
        return f"Scale failed: {e.response['Error']['Message']}"


def send_alert(subject: str, message: str) -> str:
    """Publish an incident alert to the CloudKitchen SNS topic."""
    topic_arn = os.environ.get("SNS_TOPIC_ARN", "")
    if not topic_arn:
        return "SNS_TOPIC_ARN not configured"
    try:
        sns = boto3.client("sns", region_name=_REGION())
        sns.publish(TopicArn=topic_arn, Subject=subject[:100], Message=message)
        return f"Alert sent: {subject}"
    except ClientError as e:
        return f"Alert failed: {e.response['Error']['Message']}"
