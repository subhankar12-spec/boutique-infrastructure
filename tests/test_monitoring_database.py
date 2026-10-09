"""Regression checks for the dedicated PostgreSQL 16 queue bootstrap.

Integration test requires a disposable TLS database named boutique_incidents,
owned by a non-superuser CREATEROLE administrator. It revokes public privileges.
Set TEST_MONITORING_ADMIN_URL and TEST_MONITORING_ALLOW_DESTRUCTIVE=true only
for that isolated fixture. This test never accesses AWS.
"""
import importlib.util
import os
from pathlib import Path
import secrets
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, unquote, urlsplit

import psycopg
from psycopg import sql

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts/init-monitoring-database.py"
SPEC = importlib.util.spec_from_file_location("monitoring_initializer", MODULE_PATH)
initializer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(initializer)


class QueueSecretValidation(unittest.TestCase):
    def test_connection_requires_expected_identity_host_and_verified_tls(self):
        good = "postgresql://boutique_incident:test-only@queue.example:5432/boutique_incidents?sslmode=verify-full&sslrootcert=/run/queue-ca/ca.crt"
        self.assertEqual(initializer.queue_connection({"QUEUE_DATABASE_URL": good}, "queue.example"), "test-only")
        for value in [good.replace("verify-full", "prefer"),
                      good.replace("boutique_incident:", "administrator:"),
                      good.replace("/boutique_incidents?", "/orders?"),
                      good + "&options=-csearch_path%3Dpublic"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                initializer.queue_connection({"QUEUE_DATABASE_URL": value}, "queue.example")
        with self.assertRaises(ValueError):
            initializer.queue_connection({"QUEUE_DATABASE_URL": good}, "another.example")


@unittest.skipUnless(os.environ.get("TEST_MONITORING_ADMIN_URL") and
                     os.environ.get("TEST_MONITORING_ALLOW_DESTRUCTIVE") == "true",
                     "Configure an explicitly disposable TLS PostgreSQL fixture")
class PostgreSQLBootstrap(unittest.TestCase):
    def test_non_superuser_bootstrap_is_repeatable_and_schema_isolated(self):
        url = urlsplit(os.environ["TEST_MONITORING_ADMIN_URL"])
        query = parse_qs(url.query)
        if (url.scheme != "postgresql" or url.path != "/boutique_incidents"
                or query.get("sslmode") != ["verify-full"]
                or len(query.get("sslrootcert", [])) != 1):
            self.fail("Fixture must be the dedicated disposable TLS database")
        admin = {"username": unquote(url.username), "password": unquote(url.password)}
        ca_file = Path(query["sslrootcert"][0])
        params = dict(host=url.hostname, port=url.port or 5432,
                      dbname="boutique_incidents", sslmode="verify-full",
                      sslrootcert=str(ca_file))
        with psycopg.connect(**params, user=admin["username"], password=admin["password"]) as conn:
            self.assertEqual(conn.execute("SELECT rolsuper FROM pg_roles WHERE rolname=current_user").fetchone(), (False,))
        password = secrets.token_urlsafe(32)
        real_connect = psycopg.connect

        def connect_fixture(**kwargs):
            kwargs["port"] = params["port"]
            return real_connect(**kwargs)

        # An explicit fixture port may differ from RDS's fixed 5432 endpoint.
        with patch.object(initializer.psycopg, "connect", connect_fixture):
            initializer.initialize(admin, password, params["host"], ca_file)
            initializer.initialize(admin, password, params["host"], ca_file)

        name = "bootstrap_check_" + secrets.token_hex(4)
        runtime = dict(params, user="boutique_incident", password=password)
        with real_connect(**runtime) as conn:
            conn.execute(sql.SQL("CREATE TABLE {} (id integer)").format(sql.Identifier(name)))
            conn.execute(sql.SQL("INSERT INTO {} VALUES (1)").format(sql.Identifier(name)))
            self.assertEqual(conn.execute(sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(name))).fetchone(), (1,))
            conn.execute(sql.SQL("DROP TABLE {}").format(sql.Identifier(name)))
        with self.assertRaises(psycopg.errors.InsufficientPrivilege):
            with real_connect(**runtime) as conn:
                conn.execute(sql.SQL("CREATE TABLE public.{} (id integer)").format(sql.Identifier(name)))
        with self.assertRaises(psycopg.errors.InsufficientPrivilege):
            with real_connect(**runtime) as conn:
                conn.execute("CREATE SCHEMA disallowed_schema")


if __name__ == "__main__":
    unittest.main()
