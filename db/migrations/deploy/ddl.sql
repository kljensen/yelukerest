BEGIN;

--
-- PostgreSQL database dump
--

-- Dumped from database version 10.4 (Debian 10.4-2.pgdg90+1)
-- Dumped by pg_dump version 12.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: api; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA api;


ALTER SCHEMA api OWNER TO superuser;

--
-- Name: auth; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA auth;


ALTER SCHEMA auth OWNER TO superuser;

--
-- Name: data; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA data;


ALTER SCHEMA data OWNER TO superuser;

--
-- Name: pgjwt; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA pgjwt;


ALTER SCHEMA pgjwt OWNER TO superuser;

--
-- Name: rabbitmq; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA rabbitmq;


ALTER SCHEMA rabbitmq OWNER TO superuser;

--
-- Name: request; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA request;


ALTER SCHEMA request OWNER TO superuser;

--
-- Name: settings; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA settings;


ALTER SCHEMA settings OWNER TO superuser;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: user; Type: TYPE; Schema: api; Owner: superuser
--

CREATE TYPE api."user" AS (
	id integer,
	netid text,
	email text,
	role text
);


ALTER TYPE api."user" OWNER TO superuser;

--
-- Name: participation_enum; Type: TYPE; Schema: data; Owner: superuser
--

CREATE TYPE data.participation_enum AS ENUM (
    'absent',
    'attended',
    'contributed',
    'led'
);


ALTER TYPE data.participation_enum OWNER TO superuser;

--
-- Name: user_role; Type: TYPE; Schema: data; Owner: superuser
--

CREATE TYPE data.user_role AS ENUM (
    'student',
    'faculty',
    'observer',
    'ta'
);


ALTER TYPE data.user_role OWNER TO superuser;

--
-- Name: _time_trial_type; Type: TYPE; Schema: public; Owner: superuser
--

CREATE TYPE public._time_trial_type AS (
	a_time numeric
);


ALTER TYPE public._time_trial_type OWNER TO superuser;

SET default_tablespace = '';

--
-- Name: quiz_answer; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.quiz_answer (
    quiz_id integer NOT NULL,
    user_id integer NOT NULL,
    quiz_question_option_id integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_answer OWNER TO superuser;

--
-- Name: save_quiz(integer, integer[]); Type: FUNCTION; Schema: api; Owner: superuser
--

CREATE FUNCTION api.save_quiz(quiz_id integer, quiz_question_option_ids integer[]) RETURNS SETOF data.quiz_answer
    LANGUAGE plpgsql
    AS $_$
BEGIN
    -- Functions are executed in a transaction.
    -- Delete all quiz_answers for this user's quiz_submission for this quiz_id.
    DELETE FROM api.quiz_answers qa WHERE qa.quiz_id = $1 AND qa.user_id = request.user_id();
    -- Insert the submitted quiz answers.
    INSERT INTO api.quiz_answers(quiz_question_option_id, user_id, quiz_id) select unnest($2), request.user_id(), $1;
    -- Return all quiz answers for this quiz_id.
    RETURN QUERY
        SELECT * FROM api.quiz_answers qa WHERE qa.quiz_id = $1 AND qa.user_id=request.user_id();
END; $_$;


ALTER FUNCTION api.save_quiz(quiz_id integer, quiz_question_option_ids integer[]) OWNER TO superuser;

--
-- Name: sign_jwt(integer, data.user_role); Type: FUNCTION; Schema: auth; Owner: superuser
--

CREATE FUNCTION auth.sign_jwt(user_id integer, role data.user_role) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
    select pgjwt.sign(
      json_build_object(
        'user_id', user_id,
        'role', "role"::TEXT,
        'exp', extract(epoch from now())::integer + settings.get('jwt_lifetime')::int -- token expires in 1 hour
      ),
      settings.get('jwt_secret'))
$$;


ALTER FUNCTION auth.sign_jwt(user_id integer, role data.user_role) OWNER TO superuser;

--
-- Name: clean_user_fields(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.clean_user_fields() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.email := lower(NEW.email);
    NEW.netid := lower(NEW.netid);
    NEW.nickname := lower(NEW.nickname);
    NEW.updated_at = current_timestamp;
    return NEW;
END;
$$;


ALTER FUNCTION data.clean_user_fields() OWNER TO superuser;

--
-- Name: fill_answer_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_answer_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Fill in the quiz_id if it is null
    IF (NEW.quiz_id IS NULL) THEN
        SELECT quiz_id INTO NEW.quiz_id
        FROM api.quiz_question_options
        WHERE id = NEW.quiz_question_option_id;
    END IF;
    IF (NEW.user_id IS NULL and request.user_id() IS NOT NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_answer_defaults() OWNER TO superuser;

--
-- Name: fill_assignment_field_submission_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_assignment_field_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Fill in the assignment_slug if it is NULL by looking
    -- at the assignment_slug from the assignment_submission.
    IF (NEW.assignment_slug IS NULL AND NEW.assignment_submission_id IS NOT NULL) THEN
        SELECT assignment_slug INTO NEW.assignment_slug
        FROM api.assignment_submissions
        WHERE id = NEW.assignment_submission_id;
    END IF;
    -- Fill in the assignment_submission_id if it is null
    -- by looking at the assignment if the assignment_slug
    -- is not null.
    IF (NEW.assignment_submission_id IS NULL and NEW.assignment_slug IS NOT NULL and request.user_id() IS NOT NULL) THEN
        SELECT ass.id INTO NEW.assignment_submission_id
        FROM
            (api.assignment_submissions ass
            LEFT OUTER JOIN api.users u
            ON u.team_nickname = ass.team_nickname)
        WHERE (
            -- It is the right assignment
            assignment_slug = NEW.assignment_slug
            AND
            -- It is theirs or their teams assignment submission
            (u.id = request.user_id() OR user_id = request.user_id())
        );
    END IF;

    -- Try to fill in the `submitter_user_id`
    IF (request.user_id() IS NULL ) THEN
        IF (NEW.submitter_user_id IS NULL ) THEN
            -- In practice this should only be the case when an
            -- administrator is using the database directly and
            -- not through the API.
            SELECT submitter_user_id INTO NEW.submitter_user_id
            FROM api.assignment_submissions AS sub
            WHERE sub.id = NEW.assignment_submission_id;
        END IF;
    ELSE
        NEW.submitter_user_id = request.user_id();
    END IF;

    -- Try to fill in `pattern`
    IF (NEW.assignment_field_pattern is NULL) THEN
        SELECT pattern INTO NEW.assignment_field_pattern
        FROM api.assignment_fields AS af
        WHERE NEW.assignment_field_slug=af.slug AND NEW.assignment_slug = af.assignment_slug;
    END IF;

    -- Try to fill in `is_url`
    IF (NEW.assignment_field_is_url is NULL) THEN
        SELECT is_url INTO NEW.assignment_field_is_url
        FROM api.assignment_fields AS af
        WHERE NEW.assignment_field_slug=af.slug AND NEW.assignment_slug = af.assignment_slug;
    END IF;

    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_field_submission_defaults() OWNER TO superuser;

--
-- Name: fill_assignment_grade_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_assignment_grade_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW.assignment_slug IS NULL) THEN
        SELECT ass_sub.assignment_slug INTO NEW.assignment_slug
        FROM api.assignment_submissions as ass_sub
        WHERE ass_sub.id = NEW.assignment_submission_id;
    END IF;
    IF (NEW.points_possible IS NULL) THEN
        SELECT points_possible INTO NEW.points_possible
        FROM api.assignments
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_grade_defaults() OWNER TO superuser;

--
-- Name: fill_assignment_grade_exception_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_assignment_grade_exception_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Set default is_team from assignment table
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM api.assignments
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_grade_exception_defaults() OWNER TO superuser;

--
-- Name: fill_assignment_submission_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_assignment_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Set default is_team from assignment table
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM api.assignments
        WHERE slug = NEW.assignment_slug;
    END IF;
    -- Set default user_id from request credentials
    IF (NEW.user_id IS NULL AND NOT NEW.is_team ) THEN
        NEW.user_id = request.user_id();
    END IF;
    -- Set default submitter_user_id. This is done in 
    -- the table defaults, but we do it here so that
    -- we can fill in team nickname below.
    IF (NEW.submitter_user_id IS NULL ) THEN
        IF (request.user_id() IS NULL ) THEN
            IF (NEW.user_id IS NOT NULL) THEN
                NEW.submitter_user_id = NEW.user_id;
            END IF;
        ELSE
            NEW.submitter_user_id = request.user_id();
        END IF;
    END IF;
    -- Set default team_nickname from user table
    IF (NEW.is_team AND NEW.team_nickname IS NULL) THEN
        SELECT team_nickname INTO NEW.team_nickname
        FROM api.users
        WHERE api.users.id = NEW.submitter_user_id;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_submission_defaults() OWNER TO superuser;

--
-- Name: fill_grade_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_grade_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_grade_defaults() OWNER TO superuser;

--
-- Name: fill_grade_snapshot_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_grade_snapshot_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_grade_snapshot_defaults() OWNER TO superuser;

--
-- Name: fill_quiz_grade_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_quiz_grade_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Fill in the quiz_id if it is null
    IF (NEW.points_possible IS NULL) THEN
        SELECT points_possible INTO NEW.points_possible
        FROM api.quizzes
        WHERE id = NEW.quiz_id;
    END IF;
    IF (NEW.user_id IS NULL and request.user_id() IS NOT NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_quiz_grade_defaults() OWNER TO superuser;

--
-- Name: fill_quiz_submission_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_quiz_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW.user_id IS NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_quiz_submission_defaults() OWNER TO superuser;

--
-- Name: fill_user_secret_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_user_secret_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_user_secret_defaults() OWNER TO superuser;

--
-- Name: quiz_set_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.quiz_set_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (NEW.closed_at IS NULL) THEN
    SELECT begins_at INTO NEW.closed_at
    FROM api.meetings
    WHERE slug = NEW.meeting_slug;
  END IF;
  IF (NEW.open_at IS NULL) THEN
    SELECT (begins_at - '5 days'::INTERVAL) INTO NEW.open_at
    FROM api.meetings
    WHERE slug = NEW.meeting_slug;
  END IF;
  NEW.updated_at = current_timestamp;
  RETURN NEW;
END; $$;


ALTER FUNCTION data.quiz_set_defaults() OWNER TO superuser;

--
-- Name: text_is_url(text); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.text_is_url(text) RETURNS boolean
    LANGUAGE sql STABLE
    AS $_$
    SELECT $1 ~* '^https?://[a-z0-9]+'
$_$;


ALTER FUNCTION data.text_is_url(text) OWNER TO superuser;

--
-- Name: text_matches(text, text); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.text_matches(text, text) RETURNS boolean
    LANGUAGE sql STABLE
    AS $_$
    select $1 ~ ('^(?:' || $2 || ')$')
$_$;


ALTER FUNCTION data.text_matches(text, text) OWNER TO superuser;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.update_updated_at_column() OWNER TO superuser;

--
-- Name: algorithm_sign(text, text, text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION pgjwt.algorithm_sign(signables text, secret text, algorithm text) RETURNS text
    LANGUAGE sql
    AS $$
WITH
  alg AS (
    SELECT CASE
      WHEN algorithm = 'HS256' THEN 'sha256'
      WHEN algorithm = 'HS384' THEN 'sha384'
      WHEN algorithm = 'HS512' THEN 'sha512'
      ELSE '' END)  -- hmac throws error
SELECT pgjwt.url_encode(public.hmac(signables, secret, (select * FROM alg)));
$$;


ALTER FUNCTION pgjwt.algorithm_sign(signables text, secret text, algorithm text) OWNER TO superuser;

--
-- Name: sign(json, text, text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION pgjwt.sign(payload json, secret text, algorithm text DEFAULT 'HS256'::text) RETURNS text
    LANGUAGE sql
    AS $$
WITH
  header AS (
    SELECT pgjwt.url_encode(convert_to('{"alg":"' || algorithm || '","typ":"JWT"}', 'utf8'))
    ),
  payload AS (
    SELECT pgjwt.url_encode(convert_to(payload::text, 'utf8'))
    ),
  signables AS (
    SELECT (SELECT * FROM header) || '.' || (SELECT * FROM payload)
    )
SELECT
    (SELECT * FROM signables)
    || '.' ||
    pgjwt.algorithm_sign((SELECT * FROM signables), secret, algorithm);
$$;


ALTER FUNCTION pgjwt.sign(payload json, secret text, algorithm text) OWNER TO superuser;

--
-- Name: url_decode(text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION pgjwt.url_decode(data text) RETURNS bytea
    LANGUAGE sql
    AS $$
WITH t AS (SELECT translate(data, '-_', '+/')),
     rem AS (SELECT length((SELECT * FROM t)) % 4) -- compute padding size
    SELECT decode(
        (SELECT * FROM t) ||
        CASE WHEN (SELECT * FROM rem) > 0
           THEN repeat('=', (4 - (SELECT * FROM rem)))
           ELSE '' END,
    'base64');
$$;


ALTER FUNCTION pgjwt.url_decode(data text) OWNER TO superuser;

--
-- Name: url_encode(bytea); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION pgjwt.url_encode(data bytea) RETURNS text
    LANGUAGE sql
    AS $$
    SELECT translate(encode(data, 'base64'), E'+/=\n', '-_');
$$;


ALTER FUNCTION pgjwt.url_encode(data bytea) OWNER TO superuser;

--
-- Name: verify(text, text, text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION pgjwt.verify(token text, secret text, algorithm text DEFAULT 'HS256'::text) RETURNS TABLE(header json, payload json, valid boolean)
    LANGUAGE sql
    AS $$
  SELECT
    convert_from(pgjwt.url_decode(r[1]), 'utf8')::json AS header,
    convert_from(pgjwt.url_decode(r[2]), 'utf8')::json AS payload,
    r[3] = pgjwt.algorithm_sign(r[1] || '.' || r[2], secret, algorithm) AS valid
  FROM regexp_split_to_array(token, '\.') r;
$$;


ALTER FUNCTION pgjwt.verify(token text, secret text, algorithm text) OWNER TO superuser;

--
-- Name: on_row_change(); Type: FUNCTION; Schema: rabbitmq; Owner: superuser
--

CREATE FUNCTION rabbitmq.on_row_change() RETURNS trigger
    LANGUAGE plpgsql STABLE
    AS $$
  declare
    routing_key text;
    row record;
  begin
    routing_key := 'row_change'
                   '.table-'::text || TG_TABLE_NAME::text || 
                   '.event-'::text || TG_OP::text;
    if (TG_OP = 'DELETE') then
        row := old;
    elsif (TG_OP = 'UPDATE') then
        row := new;
    elsif (TG_OP = 'INSERT') then
        row := new;
    end if;
    perform rabbitmq.send_message('events', routing_key, row_to_json(row)::text);
    return null;
  end;
$$;


ALTER FUNCTION rabbitmq.on_row_change() OWNER TO superuser;

--
-- Name: send_message(text, text, text); Type: FUNCTION; Schema: rabbitmq; Owner: superuser
--

CREATE FUNCTION rabbitmq.send_message(channel text, routing_key text, message text) RETURNS void
    LANGUAGE sql STABLE
    AS $$
     
  select  pg_notify(
    channel,  
    routing_key || '|' || message
  );
$$;


ALTER FUNCTION rabbitmq.send_message(channel text, routing_key text, message text) OWNER TO superuser;

--
-- Name: app_name(); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION request.app_name() RETURNS text
    LANGUAGE sql STABLE
    AS $$
    select request.jwt_claim('app_name')::text;
$$;


ALTER FUNCTION request.app_name() OWNER TO superuser;

--
-- Name: cookie(text); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION request.cookie(c text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    select request.env_var('request.cookie.' || c);
$$;


ALTER FUNCTION request.cookie(c text) OWNER TO superuser;

--
-- Name: env_var(text); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION request.env_var(v text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    select current_setting(v, true);
$$;


ALTER FUNCTION request.env_var(v text) OWNER TO superuser;

--
-- Name: header(text); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION request.header(h text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    select request.env_var('request.header.' || h);
$$;


ALTER FUNCTION request.header(h text) OWNER TO superuser;

--
-- Name: jwt_claim(text); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION request.jwt_claim(c text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    select request.env_var('request.jwt.claim.' || c);
$$;


ALTER FUNCTION request.jwt_claim(c text) OWNER TO superuser;

--
-- Name: user_id(); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION request.user_id() RETURNS integer
    LANGUAGE sql STABLE
    AS $$
    select 
    case request.jwt_claim('user_id') 
    when '' then 0
    else request.jwt_claim('user_id')::int
	end
$$;


ALTER FUNCTION request.user_id() OWNER TO superuser;

--
-- Name: user_role(); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION request.user_role() RETURNS text
    LANGUAGE sql STABLE
    AS $$
    select request.jwt_claim('role')::text;
$$;


ALTER FUNCTION request.user_role() OWNER TO superuser;

--
-- Name: get(text); Type: FUNCTION; Schema: settings; Owner: superuser
--

CREATE FUNCTION settings.get(text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $_$
    select value from settings.secrets where key = $1
$_$;


ALTER FUNCTION settings.get(text) OWNER TO superuser;

--
-- Name: set(text, text); Type: FUNCTION; Schema: settings; Owner: superuser
--

CREATE FUNCTION settings.set(text, text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    AS $_$
	insert into settings.secrets (key, value)
	values ($1, $2)
	on conflict (key) do update
	set value = $2;
$_$;


ALTER FUNCTION settings.set(text, text) OWNER TO superuser;

--
-- Name: assignment_field_submission; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment_field_submission (
    assignment_submission_id integer NOT NULL,
    assignment_field_slug text NOT NULL,
    assignment_slug text NOT NULL,
    assignment_field_is_url boolean NOT NULL,
    assignment_field_pattern text NOT NULL,
    body text NOT NULL,
    submitter_user_id integer DEFAULT request.user_id() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT body_matches_is_url CHECK (((assignment_field_is_url IS FALSE) OR data.text_is_url(body))),
    CONSTRAINT body_matches_pattern CHECK (data.text_matches(body, assignment_field_pattern))
);


ALTER TABLE data.assignment_field_submission OWNER TO superuser;

--
-- Name: assignment_field_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_field_submissions AS
 SELECT assignment_field_submission.assignment_submission_id,
    assignment_field_submission.assignment_field_slug,
    assignment_field_submission.assignment_slug,
    assignment_field_submission.assignment_field_is_url,
    assignment_field_submission.assignment_field_pattern,
    assignment_field_submission.body,
    assignment_field_submission.submitter_user_id,
    assignment_field_submission.created_at,
    assignment_field_submission.updated_at
   FROM data.assignment_field_submission;


ALTER TABLE api.assignment_field_submissions OWNER TO api;

--
-- Name: assignment_field; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment_field (
    slug text NOT NULL,
    assignment_slug character varying(100) NOT NULL,
    label character varying(100) NOT NULL,
    help character varying(200) NOT NULL,
    placeholder character varying(100) NOT NULL,
    is_url boolean DEFAULT false NOT NULL,
    is_multiline boolean DEFAULT false NOT NULL,
    display_order smallint DEFAULT 0 NOT NULL,
    pattern text DEFAULT '.*'::text NOT NULL,
    example text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_field_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 30))),
    CONSTRAINT pattern_matches_example CHECK (data.text_matches(example, pattern)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at)),
    CONSTRAINT url_matches_example CHECK (((is_url IS FALSE) OR ((is_url IS TRUE) AND data.text_is_url(example)))),
    CONSTRAINT url_not_multiline CHECK ((NOT (is_url AND is_multiline)))
);


ALTER TABLE data.assignment_field OWNER TO superuser;

--
-- Name: assignment_fields; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_fields AS
 SELECT assignment_field.slug,
    assignment_field.assignment_slug,
    assignment_field.label,
    assignment_field.help,
    assignment_field.placeholder,
    assignment_field.is_url,
    assignment_field.is_multiline,
    assignment_field.display_order,
    assignment_field.pattern,
    assignment_field.example,
    assignment_field.created_at,
    assignment_field.updated_at
   FROM data.assignment_field;


ALTER TABLE api.assignment_fields OWNER TO api;

--
-- Name: assignment_grade; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment_grade (
    assignment_slug character varying(100) NOT NULL,
    points_possible smallint NOT NULL,
    assignment_submission_id integer NOT NULL,
    points real NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT points_in_range CHECK (((points >= (0)::double precision) AND (points <= (points_possible)::double precision))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment_grade OWNER TO superuser;

--
-- Name: assignment_submission; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment_submission (
    id integer NOT NULL,
    assignment_slug character varying(100),
    is_team boolean,
    user_id integer,
    team_nickname character varying(50),
    submitter_user_id integer DEFAULT request.user_id() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT matches_assignment_is_team CHECK (((is_team AND (team_nickname IS NOT NULL) AND (user_id IS NULL)) OR ((NOT is_team) AND (team_nickname IS NULL) AND (user_id IS NOT NULL)))),
    CONSTRAINT submitter_matches_user_id CHECK ((is_team OR ((NOT is_team) AND (user_id = submitter_user_id)))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment_submission OWNER TO superuser;

--
-- Name: user; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data."user" (
    id integer NOT NULL,
    email character varying(100),
    netid character varying(10) NOT NULL,
    name character varying(100),
    lastname character varying(100),
    organization character varying(200),
    known_as character varying(50),
    nickname character varying(50) NOT NULL,
    role data.user_role DEFAULT (settings.get('auth.default-role'::text))::data.user_role NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    team_nickname character varying(50),
    CONSTRAINT user_check CHECK ((updated_at >= created_at)),
    CONSTRAINT user_email_check CHECK (((email)::text ~ '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'::text)),
    CONSTRAINT user_netid_check CHECK (((netid)::text ~ '^[a-z]+[0-9]+$'::text)),
    CONSTRAINT user_nickname_check CHECK (((nickname)::text ~ '^[\w]{2,20}-[\w]{2,20}$'::text))
);


ALTER TABLE data."user" OWNER TO superuser;

--
-- Name: assignment_grade_distributions; Type: VIEW; Schema: api; Owner: superuser
--

CREATE VIEW api.assignment_grade_distributions AS
 SELECT sub.assignment_slug,
    count(sub.id) AS count,
    avg(assignment_grade.points) AS average,
    min(assignment_grade.points) AS min,
    max(assignment_grade.points) AS max,
    max(assignment_grade.points_possible) AS points_possible,
    stddev_pop(assignment_grade.points) AS stddev,
    array_agg(assignment_grade.points ORDER BY assignment_grade.points) AS grades
   FROM ((data.assignment_grade
     JOIN data.assignment_submission sub ON ((assignment_grade.assignment_submission_id = sub.id)))
     JOIN data."user" u ON (((sub.user_id = u.id) OR ((sub.team_nickname)::text = (u.team_nickname)::text))))
  WHERE (u.role = 'student'::data.user_role)
  GROUP BY sub.assignment_slug;


ALTER TABLE api.assignment_grade_distributions OWNER TO superuser;

--
-- Name: VIEW assignment_grade_distributions; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON VIEW api.assignment_grade_distributions IS 'Statics on the grades received by students for each assignment';


--
-- Name: COLUMN assignment_grade_distributions.assignment_slug; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.assignment_slug IS 'The slug for the assignment to which these statistics correspond';


--
-- Name: COLUMN assignment_grade_distributions.count; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.count IS 'The number of students with grades for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.average; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.average IS 'The average grade among students for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.min; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.min IS 'The minmum grade among students for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.max; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.max IS 'The maximum grade among students for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.points_possible; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.points_possible IS 'The number of points possible for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.stddev; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.stddev IS 'The standard deviation of student grades for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.grades; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.grades IS 'The grades received by students for this assignment in ascending order';


--
-- Name: assignment_grade_exception; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment_grade_exception (
    id integer NOT NULL,
    assignment_slug character varying(100),
    is_team boolean NOT NULL,
    user_id integer,
    team_nickname character varying(50),
    fractional_credit numeric DEFAULT 1 NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_grade_exception_fractional_credit_check CHECK (((fractional_credit >= (0)::numeric) AND (fractional_credit <= (1)::numeric))),
    CONSTRAINT matches_assignment_is_team CHECK (((is_team AND (team_nickname IS NOT NULL) AND (user_id IS NULL)) OR ((NOT is_team) AND (team_nickname IS NULL) AND (user_id IS NOT NULL)))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment_grade_exception OWNER TO superuser;

--
-- Name: assignment_grade_exceptions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_grade_exceptions AS
 SELECT assignment_grade_exception.id,
    assignment_grade_exception.assignment_slug,
    assignment_grade_exception.is_team,
    assignment_grade_exception.user_id,
    assignment_grade_exception.team_nickname,
    assignment_grade_exception.fractional_credit,
    assignment_grade_exception.closed_at,
    assignment_grade_exception.created_at,
    assignment_grade_exception.updated_at
   FROM data.assignment_grade_exception;


ALTER TABLE api.assignment_grade_exceptions OWNER TO api;

--
-- Name: assignment_grades; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_grades AS
 SELECT assignment_grade.assignment_slug,
    assignment_grade.points_possible,
    assignment_grade.assignment_submission_id,
    assignment_grade.points,
    assignment_grade.description,
    assignment_grade.created_at,
    assignment_grade.updated_at
   FROM data.assignment_grade;


ALTER TABLE api.assignment_grades OWNER TO api;

--
-- Name: assignment_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_submissions AS
 SELECT assignment_submission.id,
    assignment_submission.assignment_slug,
    assignment_submission.is_team,
    assignment_submission.user_id,
    assignment_submission.team_nickname,
    assignment_submission.submitter_user_id,
    assignment_submission.created_at,
    assignment_submission.updated_at
   FROM data.assignment_submission;


ALTER TABLE api.assignment_submissions OWNER TO api;

--
-- Name: assignment; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment (
    slug text NOT NULL,
    points_possible smallint NOT NULL,
    is_draft boolean DEFAULT true NOT NULL,
    is_markdown boolean DEFAULT false,
    is_team boolean DEFAULT false,
    title character varying(100) NOT NULL,
    body text NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_points_possible_check CHECK ((points_possible >= 0)),
    CONSTRAINT assignment_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 60))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment OWNER TO superuser;

--
-- Name: assignments; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignments AS
 SELECT assignment.slug,
    assignment.points_possible,
    assignment.is_draft,
    assignment.is_markdown,
    assignment.is_team,
    assignment.title,
    assignment.body,
    assignment.closed_at,
    assignment.created_at,
    assignment.updated_at,
    ((assignment.is_draft = false) AND (CURRENT_TIMESTAMP < assignment.closed_at)) AS is_open
   FROM data.assignment;


ALTER TABLE api.assignments OWNER TO api;

--
-- Name: engagement; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.engagement (
    user_id integer NOT NULL,
    meeting_slug character varying(100) NOT NULL,
    participation data.participation_enum NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.engagement OWNER TO superuser;

--
-- Name: engagements; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.engagements AS
 SELECT engagement.user_id,
    engagement.meeting_slug,
    engagement.participation,
    engagement.created_at,
    engagement.updated_at
   FROM data.engagement;


ALTER TABLE api.engagements OWNER TO api;

--
-- Name: grade_snapshot; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.grade_snapshot (
    slug text NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT grade_snapshot_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 60))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.grade_snapshot OWNER TO superuser;

--
-- Name: grade_snapshots; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.grade_snapshots AS
 SELECT grade_snapshot.slug,
    grade_snapshot.description,
    grade_snapshot.created_at,
    grade_snapshot.updated_at
   FROM data.grade_snapshot;


ALTER TABLE api.grade_snapshots OWNER TO api;

--
-- Name: VIEW grade_snapshots; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.grade_snapshots IS 'Snapshots of class grades at particular times';


--
-- Name: COLUMN grade_snapshots.slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.slug IS 'The slug, or unique identifier, of this grade snapshot';


--
-- Name: COLUMN grade_snapshots.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.description IS 'The description of this grade snapshot. This might tell you how the grades were computed for this snapshot.';


--
-- Name: COLUMN grade_snapshots.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.created_at IS 'When this snapshot was created';


--
-- Name: COLUMN grade_snapshots.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.updated_at IS 'When this snapshot was last updated';


--
-- Name: grade; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.grade (
    points real NOT NULL,
    snapshot_slug text NOT NULL,
    user_id integer NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT grade_points_check CHECK ((points >= (0)::double precision)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.grade OWNER TO superuser;

--
-- Name: grades; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.grades AS
 SELECT grade.points,
    grade.snapshot_slug,
    grade.user_id,
    grade.description,
    grade.created_at,
    grade.updated_at
   FROM data.grade;


ALTER TABLE api.grades OWNER TO api;

--
-- Name: meeting; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.meeting (
    title character varying(250) NOT NULL,
    slug text NOT NULL,
    summary text,
    description text NOT NULL,
    begins_at timestamp with time zone NOT NULL,
    duration interval NOT NULL,
    is_draft boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT meeting_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 60))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.meeting OWNER TO superuser;

--
-- Name: meetings; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.meetings AS
 SELECT meeting.title,
    meeting.slug,
    meeting.summary,
    meeting.description,
    meeting.begins_at,
    meeting.duration,
    meeting.is_draft,
    meeting.created_at,
    meeting.updated_at
   FROM data.meeting;


ALTER TABLE api.meetings OWNER TO api;

--
-- Name: VIEW meetings; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.meetings IS 'An in-person meeting of our class, usually a lecture';


--
-- Name: COLUMN meetings.slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.slug IS 'A short identifier, appropriate for URLs, like "sql-intro"';


--
-- Name: COLUMN meetings.summary; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.summary IS 'A short description of the meeting in Markdown format';


--
-- Name: COLUMN meetings.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.description IS 'A long description of the meeting in Markdown format';


--
-- Name: COLUMN meetings.begins_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.begins_at IS 'The time at which the meeting begins, including timezone';


--
-- Name: COLUMN meetings.duration; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.duration IS 'The duration of the meeting as a Postgres interval';


--
-- Name: COLUMN meetings.is_draft; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.is_draft IS 'An indicator of if the content is still changing';


--
-- Name: COLUMN meetings.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.created_at IS 'The time this database entry was created, including timezone';


--
-- Name: COLUMN meetings.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.updated_at IS 'The most recent time this database entry was updated, including timezone';


--
-- Name: quiz_answers; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_answers AS
 SELECT quiz_answer.quiz_id,
    quiz_answer.user_id,
    quiz_answer.quiz_question_option_id,
    quiz_answer.created_at,
    quiz_answer.updated_at
   FROM data.quiz_answer;


ALTER TABLE api.quiz_answers OWNER TO api;

--
-- Name: quiz_grade; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.quiz_grade (
    quiz_id integer NOT NULL,
    points real NOT NULL,
    points_possible smallint NOT NULL,
    description text,
    user_id integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT points_in_range CHECK (((points >= (0)::double precision) AND (points <= (points_possible)::double precision))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_grade OWNER TO superuser;

--
-- Name: quiz_grade_distributions; Type: VIEW; Schema: api; Owner: superuser
--

CREATE VIEW api.quiz_grade_distributions AS
 SELECT quiz_grade.quiz_id,
    count(quiz_grade.user_id) AS count,
    avg(quiz_grade.points) AS average,
    min(quiz_grade.points) AS min,
    max(quiz_grade.points) AS max,
    max(quiz_grade.points_possible) AS points_possible,
    stddev_pop(quiz_grade.points) AS stddev,
    array_agg(quiz_grade.points ORDER BY quiz_grade.points) AS grades
   FROM (data.quiz_grade
     JOIN data."user" ON ((quiz_grade.user_id = "user".id)))
  WHERE ("user".role = 'student'::data.user_role)
  GROUP BY quiz_grade.quiz_id;


ALTER TABLE api.quiz_grade_distributions OWNER TO superuser;

--
-- Name: VIEW quiz_grade_distributions; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON VIEW api.quiz_grade_distributions IS 'Statics on the grades received by students for each quiz';


--
-- Name: COLUMN quiz_grade_distributions.quiz_id; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.quiz_id IS 'The slug for the quiz to which these statistics correspond';


--
-- Name: COLUMN quiz_grade_distributions.count; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.count IS 'The number of students with grades for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.average; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.average IS 'The average grade among students for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.min; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.min IS 'The minmum grade among students for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.max; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.max IS 'The maximum grade among students for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.points_possible; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.points_possible IS 'The number of points possible for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.stddev; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.stddev IS 'The standard deviation of student grades for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.grades; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.grades IS 'The grades received by students for this quiz in ascending order';


--
-- Name: quiz_grade_exception; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.quiz_grade_exception (
    id integer NOT NULL,
    quiz_id integer NOT NULL,
    user_id integer NOT NULL,
    fractional_credit numeric DEFAULT 1 NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT quiz_grade_exception_fractional_credit_check CHECK (((fractional_credit >= (0)::numeric) AND (fractional_credit <= (1)::numeric))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_grade_exception OWNER TO superuser;

--
-- Name: quiz_grade_exceptions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_grade_exceptions AS
 SELECT quiz_grade_exception.id,
    quiz_grade_exception.quiz_id,
    quiz_grade_exception.user_id,
    quiz_grade_exception.fractional_credit,
    quiz_grade_exception.closed_at,
    quiz_grade_exception.created_at,
    quiz_grade_exception.updated_at
   FROM data.quiz_grade_exception;


ALTER TABLE api.quiz_grade_exceptions OWNER TO api;

--
-- Name: quiz_grades; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_grades AS
 SELECT quiz_grade.quiz_id,
    quiz_grade.points,
    quiz_grade.points_possible,
    quiz_grade.description,
    quiz_grade.user_id,
    quiz_grade.created_at,
    quiz_grade.updated_at
   FROM data.quiz_grade;


ALTER TABLE api.quiz_grades OWNER TO api;

--
-- Name: quiz_question_option; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.quiz_question_option (
    id integer NOT NULL,
    quiz_question_id integer NOT NULL,
    slug text NOT NULL,
    quiz_id integer NOT NULL,
    body text NOT NULL,
    is_markdown boolean DEFAULT false NOT NULL,
    is_correct boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT quiz_question_option_slug_check CHECK (((slug ~ '^[a-z0-9][a-z0-9_-]+[a-z0-9]$'::text) AND (char_length(slug) < 100))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_question_option OWNER TO superuser;

--
-- Name: quiz_question_options; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_question_options AS
 SELECT quiz_question_option.id,
    quiz_question_option.quiz_question_id,
    quiz_question_option.slug,
    quiz_question_option.quiz_id,
    quiz_question_option.body,
    quiz_question_option.is_markdown,
    quiz_question_option.is_correct,
    quiz_question_option.created_at,
    quiz_question_option.updated_at
   FROM data.quiz_question_option;


ALTER TABLE api.quiz_question_options OWNER TO api;

--
-- Name: quiz_question; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.quiz_question (
    id integer NOT NULL,
    quiz_id integer NOT NULL,
    slug text NOT NULL,
    is_markdown boolean DEFAULT false,
    body text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT quiz_question_slug_check CHECK (((slug ~ '^[a-z0-9][a-z0-9_-]+[a-z0-9]$'::text) AND (char_length(slug) < 100))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_question OWNER TO superuser;

--
-- Name: quiz_questions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_questions AS
 SELECT quiz_question.id,
    quiz_question.quiz_id,
    quiz_question.slug,
    quiz_question.is_markdown,
    quiz_question.body,
    quiz_question.created_at,
    quiz_question.updated_at
   FROM data.quiz_question;


ALTER TABLE api.quiz_questions OWNER TO api;

--
-- Name: quiz_submission; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.quiz_submission (
    quiz_id integer NOT NULL,
    user_id integer DEFAULT request.user_id() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_submission OWNER TO superuser;

--
-- Name: quiz_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_submissions AS
 SELECT quiz_submission.quiz_id,
    quiz_submission.user_id,
    quiz_submission.created_at,
    quiz_submission.updated_at
   FROM data.quiz_submission;


ALTER TABLE api.quiz_submissions OWNER TO api;

--
-- Name: quiz; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.quiz (
    id integer NOT NULL,
    meeting_slug character varying(100) NOT NULL,
    points_possible smallint NOT NULL,
    is_draft boolean DEFAULT true NOT NULL,
    duration interval DEFAULT '00:15:00'::interval NOT NULL,
    open_at timestamp with time zone NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT closed_after_open CHECK ((closed_at > open_at)),
    CONSTRAINT quiz_points_possible_check CHECK ((points_possible >= 0)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz OWNER TO superuser;

--
-- Name: quizzes; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quizzes AS
 SELECT quiz.id,
    quiz.meeting_slug,
    quiz.points_possible,
    quiz.is_draft,
    quiz.duration,
    quiz.open_at,
    quiz.closed_at,
    quiz.created_at,
    quiz.updated_at,
    ((quiz.is_draft = false) AND (quiz.open_at < CURRENT_TIMESTAMP) AND (CURRENT_TIMESTAMP < quiz.closed_at)) AS is_open
   FROM data.quiz;


ALTER TABLE api.quizzes OWNER TO api;

--
-- Name: quiz_submissions_info; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_submissions_info AS
 SELECT qs.quiz_id,
    qs.user_id,
    qs.created_at,
    qs.updated_at,
    ((q.is_draft = false) AND (q.open_at < CURRENT_TIMESTAMP) AND (CURRENT_TIMESTAMP < LEAST(COALESCE(qge.closed_at, q.closed_at), (qs.created_at + q.duration)))) AS is_open,
    LEAST(COALESCE(qge.closed_at, q.closed_at), (qs.created_at + q.duration)) AS closed_at
   FROM ((api.quiz_submissions qs
     JOIN api.quizzes q ON ((qs.quiz_id = q.id)))
     LEFT JOIN api.quiz_grade_exceptions qge ON (((q.id = qge.quiz_id) AND (qs.user_id = qge.user_id))));


ALTER TABLE api.quiz_submissions_info OWNER TO api;

--
-- Name: team; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.team (
    nickname character varying(50) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at)),
    CONSTRAINT valid_team_nickname CHECK (((nickname)::text ~ '^[\w]{2,20}-[\w]{2,20}$'::text))
);


ALTER TABLE data.team OWNER TO superuser;

--
-- Name: teams; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.teams AS
 SELECT team.nickname,
    team.created_at,
    team.updated_at
   FROM data.team;


ALTER TABLE api.teams OWNER TO api;

--
-- Name: ui_element; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.ui_element (
    key character varying(50) NOT NULL,
    body text,
    is_markdown boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT ui_element_key_check CHECK (((key)::text ~ '^[a-z0-9\-]+$'::text)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.ui_element OWNER TO superuser;

--
-- Name: ui_elements; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.ui_elements AS
 SELECT ui_element.key,
    ui_element.body,
    ui_element.is_markdown,
    ui_element.created_at,
    ui_element.updated_at
   FROM data.ui_element;


ALTER TABLE api.ui_elements OWNER TO api;

--
-- Name: user_jwts; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.user_jwts AS
 SELECT
        CASE
            WHEN ((request.user_role() = 'faculty'::text) OR (request.user_id() = "user".id) OR ((request.user_role() = 'app'::text) AND (request.app_name() = 'authapp'::text))) THEN auth.sign_jwt("user".id, "user".role)
            ELSE NULL::text
        END AS jwt,
    "user".id,
    "user".email,
    "user".netid,
    "user".name,
    "user".lastname,
    "user".organization,
    "user".known_as,
    "user".nickname,
    "user".role,
    "user".created_at,
    "user".updated_at,
    "user".team_nickname
   FROM data."user";


ALTER TABLE api.user_jwts OWNER TO api;

--
-- Name: user_secret; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.user_secret (
    id integer NOT NULL,
    slug text NOT NULL,
    body text NOT NULL,
    user_id integer,
    team_nickname text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at)),
    CONSTRAINT user_or_team CHECK ((((team_nickname IS NOT NULL) AND (user_id IS NULL)) OR ((team_nickname IS NULL) AND (user_id IS NOT NULL)))),
    CONSTRAINT user_secret_slug_check CHECK (((slug ~ '^[a-z0-9][a-z0-9_-]+[a-z0-9]$'::text) AND (char_length(slug) < 100))),
    CONSTRAINT user_secret_team_nickname_check CHECK ((char_length(team_nickname) < 50))
);


ALTER TABLE data.user_secret OWNER TO superuser;

--
-- Name: user_secrets; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.user_secrets AS
 SELECT user_secret.id,
    user_secret.slug,
    user_secret.body,
    user_secret.user_id,
    user_secret.team_nickname,
    user_secret.created_at,
    user_secret.updated_at
   FROM data.user_secret;


ALTER TABLE api.user_secrets OWNER TO api;

--
-- Name: users; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.users AS
 SELECT "user".id,
    "user".email,
    "user".netid,
    "user".name,
    "user".lastname,
    "user".organization,
    "user".known_as,
    "user".nickname,
    "user".role,
    "user".created_at,
    "user".updated_at,
    "user".team_nickname
   FROM data."user";


ALTER TABLE api.users OWNER TO api;

--
-- Name: assignment_grade_exception_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

ALTER TABLE data.assignment_grade_exception ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.assignment_grade_exception_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: assignment_submission_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE data.assignment_submission_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE data.assignment_submission_id_seq OWNER TO superuser;

--
-- Name: assignment_submission_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE data.assignment_submission_id_seq OWNED BY data.assignment_submission.id;


--
-- Name: quiz_grade_exception_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz_grade_exception ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.quiz_grade_exception_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quiz_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE data.quiz_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE data.quiz_id_seq OWNER TO superuser;

--
-- Name: quiz_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE data.quiz_id_seq OWNED BY data.quiz.id;


--
-- Name: quiz_question_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE data.quiz_question_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE data.quiz_question_id_seq OWNER TO superuser;

--
-- Name: quiz_question_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE data.quiz_question_id_seq OWNED BY data.quiz_question.id;


--
-- Name: quiz_question_option_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE data.quiz_question_option_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE data.quiz_question_option_id_seq OWNER TO superuser;

--
-- Name: quiz_question_option_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE data.quiz_question_option_id_seq OWNED BY data.quiz_question_option.id;


--
-- Name: todo; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.todo (
    id integer NOT NULL,
    todo text NOT NULL,
    private boolean DEFAULT true,
    owner_id integer DEFAULT request.user_id()
);


ALTER TABLE data.todo OWNER TO superuser;

--
-- Name: todo_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE data.todo_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE data.todo_id_seq OWNER TO superuser;

--
-- Name: todo_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE data.todo_id_seq OWNED BY data.todo.id;


--
-- Name: user_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE data.user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE data.user_id_seq OWNER TO superuser;

--
-- Name: user_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE data.user_id_seq OWNED BY data."user".id;


--
-- Name: user_secret_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

ALTER TABLE data.user_secret ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.user_secret_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: secrets; Type: TABLE; Schema: settings; Owner: superuser
--

CREATE TABLE settings.secrets (
    key text NOT NULL,
    value text NOT NULL
);


ALTER TABLE settings.secrets OWNER TO superuser;

--
-- Name: assignment_submission id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission ALTER COLUMN id SET DEFAULT nextval('data.assignment_submission_id_seq'::regclass);


--
-- Name: quiz id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz ALTER COLUMN id SET DEFAULT nextval('data.quiz_id_seq'::regclass);


--
-- Name: quiz_question id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_question ALTER COLUMN id SET DEFAULT nextval('data.quiz_question_id_seq'::regclass);


--
-- Name: quiz_question_option id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_question_option ALTER COLUMN id SET DEFAULT nextval('data.quiz_question_option_id_seq'::regclass);


--
-- Name: todo id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.todo ALTER COLUMN id SET DEFAULT nextval('data.todo_id_seq'::regclass);


--
-- Name: user id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data."user" ALTER COLUMN id SET DEFAULT nextval('data.user_id_seq'::regclass);


--
-- Name: assignment_field assignment_field_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field
    ADD CONSTRAINT assignment_field_pkey PRIMARY KEY (slug, assignment_slug);


--
-- Name: assignment_field assignment_field_slug_assignment_slug_is_url_pattern_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field
    ADD CONSTRAINT assignment_field_slug_assignment_slug_is_url_pattern_key UNIQUE (slug, assignment_slug, is_url, pattern);


--
-- Name: assignment_field_submission assignment_field_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_pkey PRIMARY KEY (assignment_submission_id, assignment_field_slug);


--
-- Name: assignment_grade_exception assignment_grade_exception_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_pkey PRIMARY KEY (id);


--
-- Name: assignment_grade assignment_grade_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade
    ADD CONSTRAINT assignment_grade_pkey PRIMARY KEY (assignment_submission_id);


--
-- Name: assignment assignment_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment
    ADD CONSTRAINT assignment_pkey PRIMARY KEY (slug);


--
-- Name: assignment assignment_slug_is_team_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment
    ADD CONSTRAINT assignment_slug_is_team_key UNIQUE (slug, is_team);


--
-- Name: assignment assignment_slug_points_possible_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment
    ADD CONSTRAINT assignment_slug_points_possible_key UNIQUE (slug, points_possible);


--
-- Name: assignment_submission assignment_submission_id_assignment_slug_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_id_assignment_slug_key UNIQUE (id, assignment_slug);


--
-- Name: assignment_submission assignment_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_pkey PRIMARY KEY (id);


--
-- Name: engagement engagement_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.engagement
    ADD CONSTRAINT engagement_pkey PRIMARY KEY (user_id, meeting_slug);


--
-- Name: grade_snapshot grade_snapshot_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.grade_snapshot
    ADD CONSTRAINT grade_snapshot_pkey PRIMARY KEY (slug);


--
-- Name: grade grade_snapshot_slug_user_id_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.grade
    ADD CONSTRAINT grade_snapshot_slug_user_id_key UNIQUE (snapshot_slug, user_id);


--
-- Name: meeting meeting_slug_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.meeting
    ADD CONSTRAINT meeting_slug_key UNIQUE (slug);


--
-- Name: quiz_answer quiz_answer_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_answer
    ADD CONSTRAINT quiz_answer_pkey PRIMARY KEY (quiz_id, user_id, quiz_question_option_id);


--
-- Name: quiz_grade_exception quiz_grade_exception_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_pkey PRIMARY KEY (id);


--
-- Name: quiz_grade_exception quiz_grade_exception_quiz_id_user_id_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_quiz_id_user_id_key UNIQUE (quiz_id, user_id);


--
-- Name: quiz_grade quiz_grade_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_pkey PRIMARY KEY (quiz_id, user_id);


--
-- Name: quiz quiz_id_points_possible_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_id_points_possible_key UNIQUE (id, points_possible);


--
-- Name: quiz quiz_meeting_slug_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_meeting_slug_key UNIQUE (meeting_slug);


--
-- Name: quiz quiz_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_pkey PRIMARY KEY (id);


--
-- Name: quiz_question quiz_question_id_quiz_id_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_question
    ADD CONSTRAINT quiz_question_id_quiz_id_key UNIQUE (id, quiz_id);


--
-- Name: quiz_question_option quiz_question_option_id_quiz_id_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_question_option
    ADD CONSTRAINT quiz_question_option_id_quiz_id_key UNIQUE (id, quiz_id);


--
-- Name: quiz_question_option quiz_question_option_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_question_option
    ADD CONSTRAINT quiz_question_option_pkey PRIMARY KEY (id);


--
-- Name: quiz_question_option quiz_question_option_quiz_question_id_slug_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_question_option
    ADD CONSTRAINT quiz_question_option_quiz_question_id_slug_key UNIQUE (quiz_question_id, slug);


--
-- Name: quiz_question quiz_question_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_question
    ADD CONSTRAINT quiz_question_pkey PRIMARY KEY (id);


--
-- Name: quiz_question quiz_question_quiz_id_slug_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_question
    ADD CONSTRAINT quiz_question_quiz_id_slug_key UNIQUE (quiz_id, slug);


--
-- Name: quiz_submission quiz_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_submission
    ADD CONSTRAINT quiz_submission_pkey PRIMARY KEY (quiz_id, user_id);


--
-- Name: team team_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.team
    ADD CONSTRAINT team_pkey PRIMARY KEY (nickname);


--
-- Name: todo todo_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.todo
    ADD CONSTRAINT todo_pkey PRIMARY KEY (id);


--
-- Name: ui_element ui_element_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.ui_element
    ADD CONSTRAINT ui_element_pkey PRIMARY KEY (key);


--
-- Name: user user_email_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_email_key UNIQUE (email);


--
-- Name: user user_netid_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_netid_key UNIQUE (netid);


--
-- Name: user user_nickname_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_nickname_key UNIQUE (nickname);


--
-- Name: user user_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_pkey PRIMARY KEY (id);


--
-- Name: user_secret user_secret_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.user_secret
    ADD CONSTRAINT user_secret_pkey PRIMARY KEY (id);


--
-- Name: secrets secrets_pkey; Type: CONSTRAINT; Schema: settings; Owner: superuser
--

ALTER TABLE ONLY settings.secrets
    ADD CONSTRAINT secrets_pkey PRIMARY KEY (key);


--
-- Name: assignment_grade_exception_unique_team; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX assignment_grade_exception_unique_team ON data.assignment_grade_exception USING btree (assignment_slug, team_nickname) WHERE (is_team = true);


--
-- Name: assignment_grade_exception_unique_user; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX assignment_grade_exception_unique_user ON data.assignment_grade_exception USING btree (assignment_slug, user_id) WHERE (is_team = false);


--
-- Name: assignment_submission_unique_team; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX assignment_submission_unique_team ON data.assignment_submission USING btree (team_nickname, assignment_slug) WHERE (user_id IS NULL);


--
-- Name: assignment_submission_unique_user; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX assignment_submission_unique_user ON data.assignment_submission USING btree (user_id, assignment_slug) WHERE (team_nickname IS NULL);


--
-- Name: secret_unique_slug_team; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX secret_unique_slug_team ON data.user_secret USING btree (team_nickname, slug) WHERE (user_id IS NULL);


--
-- Name: secret_unique_slug_user; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX secret_unique_slug_user ON data.user_secret USING btree (user_id, slug) WHERE (team_nickname IS NULL);


--
-- Name: engagement engagement_rabbitmq_tg; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER engagement_rabbitmq_tg AFTER INSERT OR DELETE OR UPDATE ON data.engagement FOR EACH ROW EXECUTE PROCEDURE rabbitmq.on_row_change();


--
-- Name: todo send_change_event; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER send_change_event AFTER INSERT OR DELETE OR UPDATE ON data.todo FOR EACH ROW EXECUTE PROCEDURE rabbitmq.on_row_change();


--
-- Name: assignment tg_assignment_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_default BEFORE INSERT OR UPDATE ON data.assignment FOR EACH ROW EXECUTE PROCEDURE data.update_updated_at_column();


--
-- Name: assignment_field_submission tg_assignment_field_submission_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_field_submission_default BEFORE INSERT OR UPDATE ON data.assignment_field_submission FOR EACH ROW EXECUTE PROCEDURE data.fill_assignment_field_submission_defaults();


--
-- Name: assignment_grade tg_assignment_grade_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_grade_default BEFORE INSERT OR UPDATE ON data.assignment_grade FOR EACH ROW EXECUTE PROCEDURE data.fill_assignment_grade_defaults();


--
-- Name: assignment_grade_exception tg_assignment_grade_exception_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_grade_exception_default BEFORE INSERT OR UPDATE ON data.assignment_grade_exception FOR EACH ROW EXECUTE PROCEDURE data.fill_assignment_grade_exception_defaults();


--
-- Name: assignment_submission tg_assignment_submission_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_submission_default BEFORE INSERT OR UPDATE ON data.assignment_submission FOR EACH ROW EXECUTE PROCEDURE data.fill_assignment_submission_defaults();


--
-- Name: engagement tg_engagement_update_timestamps; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_engagement_update_timestamps BEFORE INSERT OR UPDATE ON data.engagement FOR EACH ROW EXECUTE PROCEDURE data.update_updated_at_column();


--
-- Name: grade tg_grade_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_grade_default BEFORE INSERT OR UPDATE ON data.grade FOR EACH ROW EXECUTE PROCEDURE data.fill_grade_defaults();


--
-- Name: grade_snapshot tg_grade_snapshot_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_grade_snapshot_default BEFORE INSERT OR UPDATE ON data.grade_snapshot FOR EACH ROW EXECUTE PROCEDURE data.fill_grade_snapshot_defaults();


--
-- Name: meeting tg_meeting_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_meeting_default BEFORE INSERT OR UPDATE ON data.meeting FOR EACH ROW EXECUTE PROCEDURE data.update_updated_at_column();


--
-- Name: quiz_answer tg_quiz_answer_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_answer_default BEFORE INSERT OR UPDATE ON data.quiz_answer FOR EACH ROW EXECUTE PROCEDURE data.fill_answer_defaults();


--
-- Name: quiz tg_quiz_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_default BEFORE INSERT OR UPDATE ON data.quiz FOR EACH ROW EXECUTE PROCEDURE data.quiz_set_defaults();


--
-- Name: quiz_grade tg_quiz_grade_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_grade_default BEFORE INSERT OR UPDATE ON data.quiz_grade FOR EACH ROW EXECUTE PROCEDURE data.fill_quiz_grade_defaults();


--
-- Name: quiz_grade_exception tg_quiz_grade_exception_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_grade_exception_default BEFORE INSERT OR UPDATE ON data.quiz_grade_exception FOR EACH ROW EXECUTE PROCEDURE data.update_updated_at_column();


--
-- Name: quiz_question tg_quiz_question_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_question_default BEFORE INSERT OR UPDATE ON data.quiz_question FOR EACH ROW EXECUTE PROCEDURE data.update_updated_at_column();


--
-- Name: quiz_question_option tg_quiz_question_option_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_question_option_default BEFORE INSERT OR UPDATE ON data.quiz_question_option FOR EACH ROW EXECUTE PROCEDURE data.update_updated_at_column();


--
-- Name: quiz_submission tg_quiz_submission_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_submission_default BEFORE INSERT OR UPDATE ON data.quiz_submission FOR EACH ROW EXECUTE PROCEDURE data.fill_quiz_submission_defaults();


--
-- Name: team tg_team_update_timestamps; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_team_update_timestamps BEFORE INSERT OR UPDATE ON data.team FOR EACH ROW EXECUTE PROCEDURE data.update_updated_at_column();


--
-- Name: ui_element tg_ui_element_update_timestamps; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_ui_element_update_timestamps BEFORE INSERT OR UPDATE ON data.ui_element FOR EACH ROW EXECUTE PROCEDURE data.update_updated_at_column();


--
-- Name: user_secret tg_user_secret_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_user_secret_default BEFORE INSERT OR UPDATE ON data.user_secret FOR EACH ROW EXECUTE PROCEDURE data.fill_user_secret_defaults();


--
-- Name: user tg_users_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_users_default BEFORE INSERT OR UPDATE ON data."user" FOR EACH ROW EXECUTE PROCEDURE data.clean_user_fields();


--
-- Name: assignment_field assignment_field_assignment_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field
    ADD CONSTRAINT assignment_field_assignment_slug_fkey FOREIGN KEY (assignment_slug) REFERENCES data.assignment(slug) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission assignment_field_submission_assignment_field_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_assignment_field_slug_fkey FOREIGN KEY (assignment_field_slug, assignment_slug, assignment_field_is_url, assignment_field_pattern) REFERENCES data.assignment_field(slug, assignment_slug, is_url, pattern) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission assignment_field_submission_assignment_submission_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_assignment_submission_id_fkey FOREIGN KEY (assignment_submission_id, assignment_slug) REFERENCES data.assignment_submission(id, assignment_slug) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission assignment_field_submission_submitter_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_submitter_user_id_fkey FOREIGN KEY (submitter_user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: assignment_grade assignment_grade_assignment_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade
    ADD CONSTRAINT assignment_grade_assignment_slug_fkey FOREIGN KEY (assignment_slug, points_possible) REFERENCES data.assignment(slug, points_possible) ON UPDATE CASCADE;


--
-- Name: assignment_grade assignment_grade_assignment_submission_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade
    ADD CONSTRAINT assignment_grade_assignment_submission_id_fkey FOREIGN KEY (assignment_submission_id, assignment_slug) REFERENCES data.assignment_submission(id, assignment_slug) ON UPDATE CASCADE;


--
-- Name: assignment_grade_exception assignment_grade_exception_assignment_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_assignment_slug_fkey FOREIGN KEY (assignment_slug, is_team) REFERENCES data.assignment(slug, is_team) ON UPDATE CASCADE;


--
-- Name: assignment_grade_exception assignment_grade_exception_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: assignment_grade_exception assignment_grade_exception_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_assignment_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_assignment_slug_fkey FOREIGN KEY (assignment_slug, is_team) REFERENCES data.assignment(slug, is_team) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_submitter_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_submitter_user_id_fkey FOREIGN KEY (submitter_user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: engagement engagement_meeting_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.engagement
    ADD CONSTRAINT engagement_meeting_slug_fkey FOREIGN KEY (meeting_slug) REFERENCES data.meeting(slug) ON UPDATE CASCADE;


--
-- Name: engagement engagement_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.engagement
    ADD CONSTRAINT engagement_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: grade grade_snapshot_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.grade
    ADD CONSTRAINT grade_snapshot_slug_fkey FOREIGN KEY (snapshot_slug) REFERENCES data.grade_snapshot(slug) ON UPDATE CASCADE;


--
-- Name: grade grade_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.grade
    ADD CONSTRAINT grade_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: quiz_answer quiz_answer_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_answer
    ADD CONSTRAINT quiz_answer_quiz_id_fkey FOREIGN KEY (quiz_id, user_id) REFERENCES data.quiz_submission(quiz_id, user_id) ON UPDATE CASCADE;


--
-- Name: quiz_answer quiz_answer_quiz_question_option_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_answer
    ADD CONSTRAINT quiz_answer_quiz_question_option_id_fkey FOREIGN KEY (quiz_question_option_id, quiz_id) REFERENCES data.quiz_question_option(id, quiz_id) ON UPDATE CASCADE;


--
-- Name: quiz_grade_exception quiz_grade_exception_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES data.quiz(id) ON UPDATE CASCADE;


--
-- Name: quiz_grade_exception quiz_grade_exception_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: quiz_grade quiz_grade_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_quiz_id_fkey FOREIGN KEY (quiz_id, points_possible) REFERENCES data.quiz(id, points_possible) ON UPDATE CASCADE;


--
-- Name: quiz_grade quiz_grade_quiz_id_fkey1; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_quiz_id_fkey1 FOREIGN KEY (quiz_id, user_id) REFERENCES data.quiz_submission(quiz_id, user_id) ON UPDATE CASCADE;


--
-- Name: quiz_grade quiz_grade_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: quiz quiz_meeting_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_meeting_slug_fkey FOREIGN KEY (meeting_slug) REFERENCES data.meeting(slug) ON UPDATE CASCADE;


--
-- Name: quiz_question_option quiz_question_option_quiz_question_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_question_option
    ADD CONSTRAINT quiz_question_option_quiz_question_id_fkey FOREIGN KEY (quiz_question_id) REFERENCES data.quiz_question(id) ON UPDATE CASCADE;


--
-- Name: quiz_question_option quiz_question_option_quiz_question_id_fkey1; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_question_option
    ADD CONSTRAINT quiz_question_option_quiz_question_id_fkey1 FOREIGN KEY (quiz_question_id, quiz_id) REFERENCES data.quiz_question(id, quiz_id) ON UPDATE CASCADE;


--
-- Name: quiz_question quiz_question_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_question
    ADD CONSTRAINT quiz_question_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES data.quiz(id) ON UPDATE CASCADE;


--
-- Name: quiz_submission quiz_submission_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_submission
    ADD CONSTRAINT quiz_submission_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES data.quiz(id) ON UPDATE CASCADE;


--
-- Name: quiz_submission quiz_submission_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_submission
    ADD CONSTRAINT quiz_submission_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: todo todo_owner_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.todo
    ADD CONSTRAINT todo_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES data."user"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: user_secret user_secret_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.user_secret
    ADD CONSTRAINT user_secret_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: user_secret user_secret_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.user_secret
    ADD CONSTRAINT user_secret_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: user user_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.assignment_field_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_field_submission assignment_field_submission_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_field_submission_access_policy ON data.assignment_field_submission TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND ((submitter_user_id = request.user_id()) OR (EXISTS ( SELECT ass_sub.id
   FROM (api.assignment_submissions ass_sub
     JOIN api.users ON (((ass_sub.user_id = users.id) OR ((ass_sub.team_nickname)::text = (users.team_nickname)::text))))
  WHERE ((users.id = request.user_id()) AND (ass_sub.id = assignment_field_submission.assignment_submission_id)))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND ((submitter_user_id = request.user_id()) AND (EXISTS ( SELECT ass_sub.id
   FROM (((api.assignment_submissions ass_sub
     JOIN api.users ON (((ass_sub.user_id = users.id) OR ((ass_sub.team_nickname)::text = (users.team_nickname)::text))))
     JOIN api.assignments ON ((assignments.slug = (ass_sub.assignment_slug)::text)))
     LEFT JOIN api.assignment_grade_exceptions ge ON ((((ge.assignment_slug)::text = (ass_sub.assignment_slug)::text) AND ((ass_sub.is_team AND ((ge.team_nickname)::text = (ass_sub.team_nickname)::text)) OR ((NOT ass_sub.is_team) AND (ge.user_id = ass_sub.user_id))))))
  WHERE ((users.id = request.user_id()) AND (ass_sub.id = assignment_field_submission.assignment_submission_id) AND ((assignments.is_open = true) OR (((ge.user_id = ass_sub.user_id) OR ((ge.team_nickname)::text = (ass_sub.team_nickname)::text)) AND (ge.closed_at > CURRENT_TIMESTAMP))))))))));


--
-- Name: assignment_grade; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.assignment_grade ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_grade assignment_grade_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_grade_access_policy ON data.assignment_grade TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (EXISTS ( SELECT ass_sub.id
   FROM api.assignment_submissions ass_sub
  WHERE (assignment_grade.assignment_submission_id = ass_sub.id)))) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: assignment_grade_exception; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.assignment_grade_exception ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_grade_exception assignment_grade_exception_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_grade_exception_access_policy ON data.assignment_grade_exception TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND ((NOT is_team) AND (request.user_id() = user_id))) OR (is_team AND (EXISTS ( SELECT u.id
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND ((u.team_nickname)::text = (assignment_grade_exception.team_nickname)::text))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: assignment_submission; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.assignment_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_submission assignment_submission_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_submission_access_policy ON data.assignment_submission TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (EXISTS ( SELECT u.id
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND ((u.team_nickname)::text = (assignment_submission.team_nickname)::text))))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND (EXISTS ( SELECT a.slug
   FROM ((api.assignments a
     LEFT JOIN api.assignment_grade_exceptions e ON ((a.slug = (e.assignment_slug)::text)))
     LEFT JOIN api.users u ON (((e.user_id = u.id) OR ((e.team_nickname)::text = (u.team_nickname)::text))))
  WHERE ((a.slug = (assignment_submission.assignment_slug)::text) AND (a.is_open OR ((e.closed_at > CURRENT_TIMESTAMP) AND (a.is_draft = false) AND ((e.user_id = assignment_submission.user_id) OR ((e.team_nickname)::text = (assignment_submission.team_nickname)::text))))))) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (EXISTS ( SELECT u.id
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND ((u.team_nickname)::text = (assignment_submission.team_nickname)::text)))))))));


--
-- Name: engagement; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.engagement ENABLE ROW LEVEL SECURITY;

--
-- Name: engagement engagement_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY engagement_access_policy ON data.engagement TO api USING ((((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = ANY ('{faculty,ta}'::text[]))));


--
-- Name: grade; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.grade ENABLE ROW LEVEL SECURITY;

--
-- Name: grade grade_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY grade_access_policy ON data.grade TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: quiz_answer; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz_answer ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_answer quiz_answer_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_answer_access_policy ON data.quiz_answer TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id) AND (EXISTS ( SELECT qsi.quiz_id,
    qsi.user_id
   FROM api.quiz_submissions_info qsi
  WHERE ((qsi.quiz_id = qsi.quiz_id) AND qsi.is_open AND (qsi.user_id = qsi.user_id)))))));


--
-- Name: quiz_grade; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz_grade ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_grade quiz_grade_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_grade_access_policy ON data.quiz_grade TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: quiz_grade_exception; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz_grade_exception ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_grade_exception quiz_grade_exception_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_grade_exception_access_policy ON data.quiz_grade_exception TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: quiz_question; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz_question ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_question quiz_question_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_question_access_policy ON data.quiz_question TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (EXISTS ( SELECT qs.quiz_id,
    qs.user_id
   FROM api.quiz_submissions qs
  WHERE ((qs.user_id = request.user_id()) AND (quiz_question.quiz_id = qs.quiz_id))))) OR (request.user_role() = 'faculty'::text)));


--
-- Name: quiz_question_option; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz_question_option ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_question_option quiz_question_option_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_question_option_access_policy ON data.quiz_question_option TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (EXISTS ( SELECT qs.quiz_id,
    qs.user_id
   FROM api.quiz_submissions qs
  WHERE ((qs.user_id = request.user_id()) AND (quiz_question_option.quiz_id = qs.quiz_id))))) OR (request.user_role() = 'faculty'::text)));


--
-- Name: quiz_submission; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_submission quiz_submission_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_submission_access_policy ON data.quiz_submission TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND ((request.user_id() = user_id) AND (EXISTS ( SELECT q.id
   FROM (api.quizzes q
     LEFT JOIN api.quiz_grade_exceptions qge ON ((q.id = qge.quiz_id)))
  WHERE ((q.id = quiz_submission.quiz_id) AND (q.is_open OR ((qge.closed_at > CURRENT_TIMESTAMP) AND (q.is_draft = false) AND (q.open_at < CURRENT_TIMESTAMP))))))))));


--
-- Name: team; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.team ENABLE ROW LEVEL SECURITY;

--
-- Name: team team_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY team_access_policy ON data.team TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND ((nickname)::text = (( SELECT users.team_nickname
   FROM api.users
  WHERE (users.id = request.user_id())))::text)) OR (request.user_role() = 'faculty'::text)));


--
-- Name: user; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data."user" ENABLE ROW LEVEL SECURITY;

--
-- Name: user user_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY user_access_policy ON data."user" TO api USING ((((request.user_role() = 'student'::text) AND (request.user_id() = id)) OR (request.user_role() = ANY ('{faculty,ta}'::text[])) OR ((request.user_role() = 'app'::text) AND (request.app_name() = 'authapp'::text))));


--
-- Name: user_secret; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.user_secret ENABLE ROW LEVEL SECURITY;

--
-- Name: user_secret user_secret_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY user_secret_access_policy ON data.user_secret TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND ((request.user_id() = user_id) OR (EXISTS ( SELECT u.id
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND ((u.team_nickname)::text = user_secret.team_nickname)))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: SCHEMA api; Type: ACL; Schema: -; Owner: superuser
--

GRANT USAGE ON SCHEMA api TO anonymous;
GRANT USAGE ON SCHEMA api TO student;
GRANT USAGE ON SCHEMA api TO ta;
GRANT USAGE ON SCHEMA api TO faculty;
GRANT USAGE ON SCHEMA api TO app;


--
-- Name: SCHEMA rabbitmq; Type: ACL; Schema: -; Owner: superuser
--

GRANT USAGE ON SCHEMA rabbitmq TO PUBLIC;


--
-- Name: SCHEMA request; Type: ACL; Schema: -; Owner: superuser
--

GRANT USAGE ON SCHEMA request TO PUBLIC;


--
-- Name: TABLE quiz_answer; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_answer TO api;


--
-- Name: FUNCTION sign_jwt(user_id integer, role data.user_role); Type: ACL; Schema: auth; Owner: superuser
--

REVOKE ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) FROM PUBLIC;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO api;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO student;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO ta;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO faculty;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO app;


--
-- Name: TABLE assignment_field_submission; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_field_submission TO api;


--
-- Name: TABLE assignment_field_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT,UPDATE ON TABLE api.assignment_field_submissions TO student;
GRANT SELECT,INSERT,UPDATE ON TABLE api.assignment_field_submissions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_field_submissions TO faculty;


--
-- Name: TABLE assignment_field; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_field TO api;


--
-- Name: TABLE assignment_fields; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignment_fields TO student;
GRANT SELECT ON TABLE api.assignment_fields TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_fields TO faculty;


--
-- Name: TABLE assignment_grade; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_grade TO api;


--
-- Name: TABLE assignment_submission; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_submission TO api;


--
-- Name: TABLE "user"; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data."user" TO api;


--
-- Name: TABLE assignment_grade_distributions; Type: ACL; Schema: api; Owner: superuser
--

GRANT SELECT ON TABLE api.assignment_grade_distributions TO student;
GRANT SELECT ON TABLE api.assignment_grade_distributions TO ta;
GRANT SELECT ON TABLE api.assignment_grade_distributions TO faculty;


--
-- Name: TABLE assignment_grade_exception; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_grade_exception TO api;


--
-- Name: TABLE assignment_grade_exceptions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignment_grade_exceptions TO student;
GRANT SELECT ON TABLE api.assignment_grade_exceptions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_grade_exceptions TO faculty;


--
-- Name: TABLE assignment_grades; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignment_grades TO student;
GRANT SELECT ON TABLE api.assignment_grades TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_grades TO faculty;


--
-- Name: TABLE assignment_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT ON TABLE api.assignment_submissions TO student;
GRANT SELECT,INSERT ON TABLE api.assignment_submissions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_submissions TO faculty;


--
-- Name: TABLE assignment; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment TO api;


--
-- Name: TABLE assignments; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignments TO student;
GRANT SELECT ON TABLE api.assignments TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignments TO faculty;


--
-- Name: TABLE engagement; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.engagement TO api;


--
-- Name: TABLE engagements; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.engagements TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.engagements TO faculty;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.engagements TO ta;


--
-- Name: TABLE grade_snapshot; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.grade_snapshot TO api;


--
-- Name: TABLE grade_snapshots; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.grade_snapshots TO student;
GRANT SELECT ON TABLE api.grade_snapshots TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.grade_snapshots TO faculty;


--
-- Name: TABLE grade; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.grade TO api;


--
-- Name: TABLE grades; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.grades TO student;
GRANT SELECT ON TABLE api.grades TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.grades TO faculty;


--
-- Name: TABLE meeting; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.meeting TO api;


--
-- Name: TABLE meetings; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.meetings TO student;
GRANT SELECT ON TABLE api.meetings TO ta;
GRANT SELECT ON TABLE api.meetings TO anonymous;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.meetings TO faculty;


--
-- Name: TABLE quiz_answers; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT,DELETE ON TABLE api.quiz_answers TO student;
GRANT SELECT,INSERT,DELETE ON TABLE api.quiz_answers TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_answers TO faculty;


--
-- Name: TABLE quiz_grade; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_grade TO api;


--
-- Name: TABLE quiz_grade_distributions; Type: ACL; Schema: api; Owner: superuser
--

GRANT SELECT ON TABLE api.quiz_grade_distributions TO student;
GRANT SELECT ON TABLE api.quiz_grade_distributions TO ta;
GRANT SELECT ON TABLE api.quiz_grade_distributions TO faculty;


--
-- Name: TABLE quiz_grade_exception; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_grade_exception TO api;


--
-- Name: TABLE quiz_grade_exceptions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quiz_grade_exceptions TO student;
GRANT SELECT ON TABLE api.quiz_grade_exceptions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_grade_exceptions TO faculty;


--
-- Name: TABLE quiz_grades; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quiz_grades TO student;
GRANT SELECT ON TABLE api.quiz_grades TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_grades TO faculty;


--
-- Name: TABLE quiz_question_option; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_question_option TO api;


--
-- Name: TABLE quiz_question_options; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_question_options TO faculty;


--
-- Name: COLUMN quiz_question_options.id; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(id) ON TABLE api.quiz_question_options TO student;
GRANT SELECT(id) ON TABLE api.quiz_question_options TO ta;


--
-- Name: COLUMN quiz_question_options.quiz_question_id; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(quiz_question_id) ON TABLE api.quiz_question_options TO student;
GRANT SELECT(quiz_question_id) ON TABLE api.quiz_question_options TO ta;


--
-- Name: COLUMN quiz_question_options.quiz_id; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(quiz_id) ON TABLE api.quiz_question_options TO student;
GRANT SELECT(quiz_id) ON TABLE api.quiz_question_options TO ta;


--
-- Name: COLUMN quiz_question_options.body; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(body) ON TABLE api.quiz_question_options TO student;
GRANT SELECT(body) ON TABLE api.quiz_question_options TO ta;


--
-- Name: COLUMN quiz_question_options.is_markdown; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(is_markdown) ON TABLE api.quiz_question_options TO student;
GRANT SELECT(is_markdown) ON TABLE api.quiz_question_options TO ta;


--
-- Name: COLUMN quiz_question_options.created_at; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(created_at) ON TABLE api.quiz_question_options TO student;
GRANT SELECT(created_at) ON TABLE api.quiz_question_options TO ta;


--
-- Name: COLUMN quiz_question_options.updated_at; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(updated_at) ON TABLE api.quiz_question_options TO student;
GRANT SELECT(updated_at) ON TABLE api.quiz_question_options TO ta;


--
-- Name: TABLE quiz_question; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_question TO api;


--
-- Name: TABLE quiz_questions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quiz_questions TO student;
GRANT SELECT ON TABLE api.quiz_questions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_questions TO faculty;


--
-- Name: TABLE quiz_submission; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_submission TO api;


--
-- Name: TABLE quiz_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT ON TABLE api.quiz_submissions TO student;
GRANT SELECT,INSERT ON TABLE api.quiz_submissions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_submissions TO faculty;


--
-- Name: TABLE quiz; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz TO api;


--
-- Name: TABLE quizzes; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quizzes TO student;
GRANT SELECT ON TABLE api.quizzes TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quizzes TO faculty;


--
-- Name: TABLE quiz_submissions_info; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quiz_submissions_info TO student;
GRANT SELECT ON TABLE api.quiz_submissions_info TO ta;
GRANT SELECT ON TABLE api.quiz_submissions_info TO faculty;


--
-- Name: TABLE team; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.team TO api;


--
-- Name: TABLE teams; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.teams TO student;
GRANT SELECT ON TABLE api.teams TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.teams TO faculty;


--
-- Name: TABLE ui_element; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.ui_element TO api;


--
-- Name: TABLE ui_elements; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.ui_elements TO student;
GRANT SELECT ON TABLE api.ui_elements TO ta;
GRANT SELECT ON TABLE api.ui_elements TO anonymous;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.ui_elements TO faculty;


--
-- Name: TABLE user_jwts; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.user_jwts TO student;
GRANT SELECT ON TABLE api.user_jwts TO ta;
GRANT SELECT ON TABLE api.user_jwts TO faculty;
GRANT SELECT ON TABLE api.user_jwts TO app;


--
-- Name: TABLE user_secret; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.user_secret TO api;


--
-- Name: TABLE user_secrets; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.user_secrets TO student;
GRANT SELECT ON TABLE api.user_secrets TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.user_secrets TO faculty;


--
-- Name: TABLE users; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.users TO student;
GRANT SELECT ON TABLE api.users TO ta;
GRANT SELECT ON TABLE api.users TO app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.users TO faculty;


--
-- Name: SEQUENCE assignment_submission_id_seq; Type: ACL; Schema: data; Owner: superuser
--

GRANT USAGE ON SEQUENCE data.assignment_submission_id_seq TO faculty;
GRANT USAGE ON SEQUENCE data.assignment_submission_id_seq TO ta;
GRANT USAGE ON SEQUENCE data.assignment_submission_id_seq TO student;


--
-- Name: SEQUENCE quiz_id_seq; Type: ACL; Schema: data; Owner: superuser
--

GRANT USAGE ON SEQUENCE data.quiz_id_seq TO faculty;


--
-- Name: SEQUENCE quiz_question_id_seq; Type: ACL; Schema: data; Owner: superuser
--

GRANT USAGE ON SEQUENCE data.quiz_question_id_seq TO student;
GRANT USAGE ON SEQUENCE data.quiz_question_id_seq TO ta;
GRANT USAGE ON SEQUENCE data.quiz_question_id_seq TO faculty;


--
-- Name: SEQUENCE quiz_question_option_id_seq; Type: ACL; Schema: data; Owner: superuser
--

GRANT USAGE ON SEQUENCE data.quiz_question_option_id_seq TO student;
GRANT USAGE ON SEQUENCE data.quiz_question_option_id_seq TO ta;
GRANT USAGE ON SEQUENCE data.quiz_question_option_id_seq TO faculty;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: -; Owner: api
--

ALTER DEFAULT PRIVILEGES FOR ROLE api REVOKE ALL ON FUNCTIONS  FROM PUBLIC;


--
-- PostgreSQL database dump complete
--

COMMIT;
