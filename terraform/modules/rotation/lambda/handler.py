"""Trigger rotation for an RDS-managed master-user secret."""

import os

import boto3


RDS = boto3.client("rds")


def lambda_handler(_event, _context):
    database_id = os.environ["DB_INSTANCE_IDENTIFIER"]
    response = RDS.modify_db_instance(
        DBInstanceIdentifier=database_id,
        RotateMasterUserPassword=True,
        ApplyImmediately=True,
    )
    return {
        "database": database_id,
        "rotation_requested": True,
        "status": response["DBInstance"]["DBInstanceStatus"],
    }
