-- create_flyway_user.sql
--
-- Creates a "flyway" login role with the same level of access as the RDS
-- master user, for use by the pipeline (Flyway migrations and the Terraform
-- postgresql provider).
--
-- Run it once per environment, as the RDS master user, connected to the
-- application database:
--
--   export FLYWAY_PASSWORD='...'   # from your secret store, not hardcoded
--   psql "host=<endpoint> port=5432 dbname=<app_db> user=<master_user> sslmode=require" \
--     -v flyway_password="$FLYWAY_PASSWORD" \
--     -v app_db=<app_db> \
--     -v master_user=<master_user> \
--     -f create_flyway_user.sql
--
-- Safe to re-run: it creates the role only if missing and re-applies grants.

\set ON_ERROR_STOP on

-- 1. Create the role if it doesn't exist yet
SELECT format(
         'CREATE ROLE flyway WITH LOGIN CREATEDB CREATEROLE PASSWORD %L',
         :'flyway_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'flyway') \gexec

-- Keep the password in sync if the role already existed
ALTER ROLE flyway WITH PASSWORD :'flyway_password';

-- 2. Same cluster-level privileges as the master user.
--    On RDS the master user is not a true superuser; its power comes from
--    membership in rds_superuser, so granting that gives the same level.
GRANT rds_superuser TO flyway;

-- 3. Full access to the application database
GRANT ALL PRIVILEGES ON DATABASE :"app_db" TO flyway;

-- 4. Existing objects in the public schema
--    (repeat this block for every other schema your app uses)
GRANT ALL ON SCHEMA public TO flyway;
GRANT ALL ON ALL TABLES    IN SCHEMA public TO flyway;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO flyway;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO flyway;

-- 5. Objects the master user creates in future get the same grants
ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA public
  GRANT ALL ON TABLES TO flyway;
ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA public
  GRANT ALL ON SEQUENCES TO flyway;
ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA public
  GRANT ALL ON FUNCTIONS TO flyway;

-- 6. Let flyway act as the owner of the master user's objects.
--    Grants alone don't allow ALTER TABLE / DROP TABLE on tables owned by
--    someone else, which migrations usually need. If this line fails with
--    "permission denied to grant role", see the notes that came with this
--    script: ownership of the existing objects has to change instead.
GRANT :"master_user" TO flyway;

-- 7. Show the result
\du flyway
