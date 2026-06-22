#!/usr/bin/env bash

TOMCAT_ROLE_NAME="kwu-prd-vpc-tomcat-secret-role"
TOMCAT_PROFILE_NAME="kwu-prd-vpc-tomcat-profile"
DB_SECRET_ARN=""

prepare_tomcat_identity() {
    local trust_policy
    local policy

    [[ -n "$DB_SECRET_ARN" && "$DB_SECRET_ARN" != "None" ]] || {
        LAST_ERROR="RDS managed secret ARN is unavailable."
        return 1
    }
    trust_policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    policy="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"$DB_SECRET_ARN\"}]}"

    aws_mutate "Create Tomcat secret access role" iam create-role \
        --role-name "$TOMCAT_ROLE_NAME" --assume-role-policy-document "$trust_policy" || true
    aws_mutate "Grant Tomcat access to RDS secret" iam put-role-policy \
        --role-name "$TOMCAT_ROLE_NAME" --policy-name ReadRdsManagedSecret --policy-document "$policy" || return 1
    aws_mutate "Create Tomcat instance profile" iam create-instance-profile \
        --instance-profile-name "$TOMCAT_PROFILE_NAME" || true
    aws_mutate "Attach Tomcat role to instance profile" iam add-role-to-instance-profile \
        --instance-profile-name "$TOMCAT_PROFILE_NAME" --role-name "$TOMCAT_ROLE_NAME" || true
    sleep 10
}
