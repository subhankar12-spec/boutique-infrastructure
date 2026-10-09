#!/usr/bin/env python3
"""Initialize the dedicated incident queue role over verified PostgreSQL TLS.

Run from the private operator network. AWS secrets remain in memory and are
never emitted. Requires boto3 and psycopg[binary] on the trusted operator host.
"""
import argparse
import json
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

import psycopg
from psycopg import sql

DATABASE = "boutique_incidents"
USERNAME = "boutique_incident"
SCHEMA = "incident_queue"


def queue_connection(secret, expected_host):
    value = secret.get("QUEUE_DATABASE_URL", "")
    parsed = urlsplit(value)
    query = parse_qs(parsed.query, strict_parsing=True)
    if (parsed.scheme != "postgresql" or parsed.hostname != expected_host
            or parsed.port not in (None, 5432) or parsed.path != "/" + DATABASE
            or unquote(parsed.username or "") != USERNAME or not parsed.password
            or parsed.fragment or set(query) != {"sslmode", "sslrootcert"}
            or query["sslmode"] != ["verify-full"]
            or query["sslrootcert"] != ["/run/queue-ca/ca.crt"]):
        raise ValueError("Queue secret does not match the expected dedicated TLS database")
    return unquote(parsed.password)


def initialize(admin, password, host, ca_file):
    connection = dict(host=host, port=5432, dbname=DATABASE,
                      sslmode="verify-full", sslrootcert=str(ca_file),
                      connect_timeout=10, options="-cstatement_timeout=10000 -clock_timeout=5000")
    with psycopg.connect(**connection, user=admin["username"], password=admin["password"]) as conn:
        with conn.cursor() as cur:
            # Do not quietly reuse a role with privileged/inherited memberships.
            cur.execute("SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON m.member=r.oid WHERE r.rolname=%s", (USERNAME,))
            if cur.fetchone():
                raise ValueError("Incident role has unexpected memberships; review before initialization")
            cur.execute("SELECT rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls FROM pg_roles WHERE rolname=%s", (USERNAME,))
            existing_flags = cur.fetchone()
            if existing_flags is not None and any(existing_flags):
                raise ValueError("Incident role has unexpected administrator privileges; review before initialization")
            # A non-superuser RDS administrator cannot ALTER SUPERUSER,
            # REPLICATION or BYPASSRLS, even when setting already-false flags.
            # Existing roles are checked above; only set those flags at CREATE.
            verb = "ALTER" if existing_flags is not None else "CREATE"
            create_flags = "" if existing_flags is not None else "NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS "
            cur.execute(sql.SQL(verb + " ROLE {} LOGIN NOINHERIT " + create_flags + "CONNECTION LIMIT 30 PASSWORD {}").format(sql.Identifier(USERNAME), sql.Literal(password)))
            # PostgreSQL 16 grants a role creator ADMIN without SET by default.
            # Creating/assigning a schema requires SET rights for its owner.
            # Grant that capability temporarily and restore its previous state.
            cur.execute("SELECT m.set_option FROM pg_auth_members m JOIN pg_roles owner ON m.roleid=owner.oid JOIN pg_roles member ON m.member=member.oid WHERE owner.rolname=%s AND member.rolname=current_user", (USERNAME,))
            previous_membership = cur.fetchone()
            cur.execute(sql.SQL("GRANT {} TO {} WITH SET TRUE").format(sql.Identifier(USERNAME), sql.Identifier(admin["username"])))
            cur.execute(sql.SQL("REVOKE ALL ON DATABASE {} FROM PUBLIC").format(sql.Identifier(DATABASE)))
            cur.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(sql.Identifier(DATABASE), sql.Identifier(USERNAME)))
            cur.execute("REVOKE ALL ON SCHEMA public FROM PUBLIC")
            cur.execute(sql.SQL("CREATE SCHEMA IF NOT EXISTS {} AUTHORIZATION {}").format(sql.Identifier(SCHEMA), sql.Identifier(USERNAME)))
            cur.execute(sql.SQL("ALTER SCHEMA {} OWNER TO {}").format(sql.Identifier(SCHEMA), sql.Identifier(USERNAME)))
            cur.execute(sql.SQL("REVOKE ALL ON SCHEMA {} FROM PUBLIC").format(sql.Identifier(SCHEMA)))
            cur.execute(sql.SQL("ALTER ROLE {} IN DATABASE {} SET search_path TO {}").format(sql.Identifier(USERNAME), sql.Identifier(DATABASE), sql.Identifier(SCHEMA)))
            if previous_membership is None:
                cur.execute(sql.SQL("REVOKE {} FROM {}").format(sql.Identifier(USERNAME), sql.Identifier(admin["username"])))
            elif not previous_membership[0]:
                cur.execute(sql.SQL("GRANT {} TO {} WITH SET FALSE").format(sql.Identifier(USERNAME), sql.Identifier(admin["username"])))
    # Verify the runtime identity, schema access and lack of administrator flags.
    with psycopg.connect(**connection, user=USERNAME, password=password) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT current_user,current_schema(),rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls FROM pg_roles WHERE rolname=current_user")
            if cur.fetchone() != (USERNAME, SCHEMA, False, False, False, False, False):
                raise ValueError("Incident runtime role verification failed")
            cur.execute("CREATE TABLE __bootstrap_permissions_check (id integer)")
            cur.execute("DROP TABLE __bootstrap_permissions_check")
    print("Dedicated incident queue role initialized and least-privilege access verified.")


def main():
    import boto3

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", required=True)
    parser.add_argument("--admin-secret", required=True)
    parser.add_argument("--queue-secret", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--ca-file", required=True, type=Path)
    parser.add_argument("--bootstrap-role", required=True)
    args = parser.parse_args()
    # Compare the reviewed local bundle with the exact bundle delivered to pods.
    reviewed_ca = args.ca_file.read_text(encoding="utf-8")
    if "-----BEGIN CERTIFICATE-----" not in reviewed_ca:
        raise ValueError("Invalid reviewed CA bundle")
    creds = boto3.client("sts", region_name=args.region).assume_role(
        RoleArn=args.bootstrap_role, RoleSessionName="incident-database-bootstrap", DurationSeconds=900)["Credentials"]
    client = boto3.client("secretsmanager", region_name=args.region,
                          aws_access_key_id=creds["AccessKeyId"],
                          aws_secret_access_key=creds["SecretAccessKey"],
                          aws_session_token=creds["SessionToken"])
    admin = json.loads(client.get_secret_value(SecretId=args.admin_secret)["SecretString"])
    queue = json.loads(client.get_secret_value(SecretId=args.queue_secret)["SecretString"])
    if queue.get("postgresql_ca") != reviewed_ca:
        raise ValueError("Reviewed local CA and queue secret CA differ")
    password = queue_connection(queue, args.host)
    initialize(admin, password, args.host, args.ca_file.resolve())


if __name__ == "__main__":
    main()
