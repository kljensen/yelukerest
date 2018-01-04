BEGIN;
\set QUIET on
\set ON_ERROR_STOP on
set client_min_messages to warning;
truncate data.todo restart identity cascade;
truncate data.user restart identity cascade;
set search_path = data, public;
\ir ./yeluke/reset.sql
\ir data.sql
COMMIT;