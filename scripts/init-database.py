#!/usr/bin/env python3
"""Run from a trusted network path after apply, before application startup.
Needs boto3 and psycopg[binary]. Values stay in memory, not logs or files.
"""
import argparse,json,boto3,psycopg
from psycopg import sql
p=argparse.ArgumentParser();p.add_argument('--region',required=True);p.add_argument('--admin-secret',required=True);p.add_argument('--app-secret',required=True);p.add_argument('--host',required=True);p.add_argument('--ca-file',required=True);a=p.parse_args()
c=boto3.client('secretsmanager',region_name=a.region)
def secret(name):return json.loads(c.get_secret_value(SecretId=name)['SecretString'])
admin=secret(a.admin_secret);app=secret(a.app_secret)
with psycopg.connect(host=a.host,dbname='boutique',user=admin['username'],password=admin['password'],sslmode='verify-full',sslrootcert=a.ca_file) as conn:
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname='boutique'")
        statement='ALTER ROLE boutique LOGIN PASSWORD {}' if cur.fetchone() else 'CREATE ROLE boutique LOGIN PASSWORD {}'
        cur.execute(sql.SQL(statement).format(sql.Literal(app['database_password'])))
        cur.execute('GRANT CONNECT ON DATABASE boutique TO boutique')
        cur.execute('CREATE SCHEMA IF NOT EXISTS application AUTHORIZATION boutique')
        cur.execute('ALTER ROLE boutique SET search_path TO application')
print('Application database role initialized. It is not the RDS admin role.')
