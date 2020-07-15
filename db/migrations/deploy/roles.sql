
-- This file was created automatically by the create-initial-migrations.sh
-- script. DO NOT EDIT BY HAND.

BEGIN;

-- When we dump the data it will include the current (dev) authenticator
-- (postgrest) user and superuser info. We don't want that. Here, we're
-- going to replace those with values from the environment. That assumes
-- that sqitch will have access to those environment variables when it
-- runs. See the "bin/sqitch.sh" wrapper via which these environment
-- variables are explicitly passed in.
\set authenticator_user `echo $DB_USER`
\set authenticator_pass `echo $DB_PASS`
\set super_user `echo $SUPER_USER`

-- Initial database roles.
--
-- PostgreSQL database cluster dump
--

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

--
-- Roles
--

CREATE ROLE anonymous;
ALTER ROLE anonymous WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
CREATE ROLE api;
ALTER ROLE api WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
CREATE ROLE app;
ALTER ROLE app WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
CREATE ROLE :authenticator_user;
ALTER ROLE :authenticator_user WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD :'authenticator_pass';
CREATE ROLE faculty;
ALTER ROLE faculty WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
CREATE ROLE observer;
ALTER ROLE observer WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
-- CREATE ROLE postgres;
-- ALTER ROLE postgres WITH SUPERUSER INHERIT CREATEROLE CREATEDB LOGIN REPLICATION BYPASSRLS;
CREATE ROLE student;
ALTER ROLE student WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
CREATE ROLE ta;
ALTER ROLE ta WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;


--
-- Role memberships
--

GRANT anonymous TO :authenticator_user GRANTED BY :super_user;
GRANT api TO :super_user GRANTED BY :super_user;
GRANT app TO :authenticator_user GRANTED BY :super_user;
GRANT faculty TO :authenticator_user GRANTED BY :super_user;
GRANT observer TO :authenticator_user GRANTED BY :super_user;
GRANT student TO :authenticator_user GRANTED BY :super_user;
GRANT ta TO :authenticator_user GRANTED BY :super_user;


--
-- PostgreSQL database cluster dump complete
--

COMMIT;
