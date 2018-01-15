--
-- PostgreSQL database cluster dump
--

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

--
-- Roles
--

-- NOTE: this migration does not include anything from
-- our app that is not hardcoded. E.g. the authenticator
-- password. Need to set that after migration ends as
-- superuser.
--
CREATE ROLE authenticator WITH login password NULL; -- have to change this manually after migration
CREATE ROLE anonymous;
CREATE ROLE api;
CREATE ROLE authapp;
CREATE ROLE faculty;
CREATE ROLE observer;
CREATE ROLE student;


--
-- Role memberships
--

GRANT anonymous TO authenticator;
GRANT api TO current_user;
GRANT faculty TO authenticator;
GRANT observer TO authenticator;
GRANT student TO authenticator;


--
-- PostgreSQL database cluster dump complete
--


--
-- PostgreSQL database dump
--

-- Dumped from database version 9.6.6
-- Dumped by pg_dump version 10.1

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: api; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA api;



--
-- Name: auth; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA auth;



--
-- Name: data; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA data;



--
-- Name: pgjwt; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA pgjwt;



--
-- Name: rabbitmq; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA rabbitmq;



--
-- Name: request; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA request;



--
-- Name: settings; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA settings;



--
-- Name: plpgsql; Type: EXTENSION; Schema: -; Owner: 
--

CREATE EXTENSION IF NOT EXISTS plpgsql WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION plpgsql; Type: COMMENT; Schema: -; Owner: 
--



--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: 
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--



SET search_path = api, pg_catalog;

--
-- Name: user; Type: TYPE; Schema: api; Owner: superuser
--

CREATE TYPE "user" AS (
	id integer,
	name text,
	email text,
	role text
);



SET search_path = data, pg_catalog;

--
-- Name: participation_enum; Type: TYPE; Schema: data; Owner: superuser
--

CREATE TYPE participation_enum AS ENUM (
    'absent',
    'attended',
    'contributed',
    'led'
);



--
-- Name: user_role; Type: TYPE; Schema: data; Owner: superuser
--

CREATE TYPE user_role AS ENUM (
    'student',
    'faculty',
    'observer'
);



SET search_path = auth, pg_catalog;

--
-- Name: encrypt_pass(); Type: FUNCTION; Schema: auth; Owner: superuser
--

CREATE FUNCTION encrypt_pass() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if new.password is not null then
  	new.password = crypt(new.password, gen_salt('bf'));
  end if;
  return new;
end
$$;



--
-- Name: get_jwt_payload(json); Type: FUNCTION; Schema: auth; Owner: superuser
--

CREATE FUNCTION get_jwt_payload(json) RETURNS json
    LANGUAGE sql STABLE
    AS $_$
    select json_build_object(
                'role', $1->'role',
                'user_id', $1->'id',
                'exp', extract(epoch from now())::integer + settings.get('jwt_lifetime')::int -- token expires in 1 hour
            )
$_$;



--
-- Name: set_auth_endpoints_privileges(text, text, text[]); Type: FUNCTION; Schema: auth; Owner: superuser
--

CREATE FUNCTION set_auth_endpoints_privileges(schema text, anonymous text, roles text[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
declare r record;
begin
  execute 'grant execute on function ' || quote_ident(schema) || '.login(text,text) to ' || quote_ident(anonymous);
  execute 'grant execute on function ' || quote_ident(schema) || '.signup(text,text,text) to ' || quote_ident(anonymous);
  for r in
     select unnest(roles) as role
  loop
     execute 'grant execute on function ' || quote_ident(schema) || '.me() to ' || quote_ident(r.role);
     execute 'grant execute on function ' || quote_ident(schema) || '.login(text,text) to ' || quote_ident(r.role);
     execute 'grant execute on function ' || quote_ident(schema) || '.refresh_token() to ' || quote_ident(r.role);
  end loop;
end;
$$;



--
-- Name: sign_jwt(json); Type: FUNCTION; Schema: auth; Owner: superuser
--

CREATE FUNCTION sign_jwt(json) RETURNS text
    LANGUAGE sql STABLE
    AS $_$
    select pgjwt.sign($1, settings.get('jwt_secret'))
$_$;



SET search_path = data, pg_catalog;

--
-- Name: clean_user_fields(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION clean_user_fields() RETURNS trigger
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



--
-- Name: fill_answer_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION fill_answer_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Fill in the quiz_id if it is null
    IF (NEW.quiz_id IS NULL) THEN
        SELECT quiz_id INTO NEW.quiz_id
        FROM quiz_question_option
        WHERE id = NEW.quiz_question_option_id;
    END IF;
    IF (NEW.user_id IS NULL and request.user_id() IS NOT NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;



--
-- Name: fill_assignment_submission_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION fill_assignment_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM api.assignments
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;



--
-- Name: quiz_set_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION quiz_set_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (NEW.closed_at IS NULL) THEN
    SELECT begins_at INTO NEW.closed_at
    FROM api.meetings
    WHERE id = NEW.meeting_id;
  END IF;
  IF (NEW.open_at IS NULL) THEN
    SELECT (begins_at - '5 days'::INTERVAL) INTO NEW.open_at
    FROM api.meetings
    WHERE id = NEW.meeting_id;
  END IF;
  NEW.updated_at = current_timestamp;
  RETURN NEW;
END; $$;



--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;



SET search_path = pgjwt, pg_catalog;

--
-- Name: algorithm_sign(text, text, text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION algorithm_sign(signables text, secret text, algorithm text) RETURNS text
    LANGUAGE sql
    AS $$
WITH
  alg AS (
    SELECT CASE
      WHEN algorithm = 'HS256' THEN 'sha256'
      WHEN algorithm = 'HS384' THEN 'sha384'
      WHEN algorithm = 'HS512' THEN 'sha512'
      ELSE '' END)  -- hmac throws error
SELECT pgjwt.url_encode(hmac(signables, secret, (select * FROM alg)));
$$;



--
-- Name: sign(json, text, text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION sign(payload json, secret text, algorithm text DEFAULT 'HS256'::text) RETURNS text
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



--
-- Name: url_decode(text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION url_decode(data text) RETURNS bytea
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



--
-- Name: url_encode(bytea); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION url_encode(data bytea) RETURNS text
    LANGUAGE sql
    AS $$
    SELECT translate(encode(data, 'base64'), E'+/=\n', '-_');
$$;



--
-- Name: verify(text, text, text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION verify(token text, secret text, algorithm text DEFAULT 'HS256'::text) RETURNS TABLE(header json, payload json, valid boolean)
    LANGUAGE sql
    AS $$
  SELECT
    convert_from(pgjwt.url_decode(r[1]), 'utf8')::json AS header,
    convert_from(pgjwt.url_decode(r[2]), 'utf8')::json AS payload,
    r[3] = pgjwt.algorithm_sign(r[1] || '.' || r[2], secret, algorithm) AS valid
  FROM regexp_split_to_array(token, '\.') r;
$$;



SET search_path = rabbitmq, pg_catalog;

--
-- Name: on_row_change(); Type: FUNCTION; Schema: rabbitmq; Owner: superuser
--

CREATE FUNCTION on_row_change() RETURNS trigger
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



--
-- Name: send_message(text, text, text); Type: FUNCTION; Schema: rabbitmq; Owner: superuser
--

CREATE FUNCTION send_message(channel text, routing_key text, message text) RETURNS void
    LANGUAGE sql STABLE
    AS $$
     
  select  pg_notify(
    channel,  
    routing_key || '|' || message
  );
$$;



SET search_path = request, pg_catalog;

--
-- Name: cookie(text); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION cookie(c text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    select request.env_var('request.cookie.' || c);
$$;



--
-- Name: env_var(text); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION env_var(v text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    select current_setting(v, true);
$$;



--
-- Name: header(text); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION header(h text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    select request.env_var('request.header.' || h);
$$;



--
-- Name: jwt_claim(text); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION jwt_claim(c text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    select request.env_var('request.jwt.claim.' || c);
$$;



--
-- Name: user_id(); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION user_id() RETURNS integer
    LANGUAGE sql STABLE
    AS $$
    select 
    case request.jwt_claim('user_id') 
    when '' then 0
    else request.jwt_claim('user_id')::int
	end
$$;



--
-- Name: user_role(); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION user_role() RETURNS text
    LANGUAGE sql STABLE
    AS $$
    select request.jwt_claim('role')::text;
$$;



SET search_path = settings, pg_catalog;

--
-- Name: get(text); Type: FUNCTION; Schema: settings; Owner: superuser
--

CREATE FUNCTION get(text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $_$
    select value from settings.secrets where key = $1
$_$;



--
-- Name: set(text, text); Type: FUNCTION; Schema: settings; Owner: superuser
--

CREATE FUNCTION set(text, text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    AS $_$
	insert into settings.secrets (key, value)
	values ($1, $2)
	on conflict (key) do update
	set value = $2;
$_$;



SET search_path = data, pg_catalog;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: assignment_field_submission; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE assignment_field_submission (
    assignment_submission_id integer NOT NULL,
    assignment_field_id integer NOT NULL,
    assignment_slug character varying(100) NOT NULL,
    body character varying(10000) NOT NULL,
    submitter_user_id integer DEFAULT request.user_id() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);



SET search_path = api, pg_catalog;

--
-- Name: assignment_field_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW assignment_field_submissions AS
 SELECT assignment_field_submission.assignment_submission_id,
    assignment_field_submission.assignment_field_id,
    assignment_field_submission.assignment_slug,
    assignment_field_submission.body,
    assignment_field_submission.submitter_user_id,
    assignment_field_submission.created_at,
    assignment_field_submission.updated_at
   FROM data.assignment_field_submission;


ALTER TABLE assignment_field_submissions OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: assignment_field; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE assignment_field (
    id integer NOT NULL,
    assignment_slug character varying(100) NOT NULL,
    label character varying(100) NOT NULL,
    help character varying(200) NOT NULL,
    placeholder character varying(100) NOT NULL,
    is_url boolean DEFAULT false NOT NULL,
    is_multiline boolean DEFAULT false NOT NULL,
    display_order smallint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at)),
    CONSTRAINT url_not_multiline CHECK ((NOT (is_url AND is_multiline)))
);



SET search_path = api, pg_catalog;

--
-- Name: assignment_fields; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW assignment_fields AS
 SELECT assignment_field.id,
    assignment_field.assignment_slug,
    assignment_field.label,
    assignment_field.help,
    assignment_field.placeholder,
    assignment_field.is_url,
    assignment_field.is_multiline,
    assignment_field.display_order,
    assignment_field.created_at,
    assignment_field.updated_at
   FROM data.assignment_field;


ALTER TABLE assignment_fields OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: assignment_submission; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE assignment_submission (
    id integer NOT NULL,
    assignment_slug character varying(100),
    is_team boolean,
    user_id integer,
    team_nickname character varying(50),
    submitter_user_id integer DEFAULT request.user_id() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT matches_assignment_is_team CHECK (((is_team AND (team_nickname IS NOT NULL) AND (user_id IS NULL)) OR ((NOT is_team) AND (team_nickname IS NULL) AND (user_id IS NOT NULL)))),
    CONSTRAINT submitter_matches_user_id CHECK ((is_team OR ((NOT is_team) AND (user_id = submitter_user_id)))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);



SET search_path = api, pg_catalog;

--
-- Name: assignment_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW assignment_submissions AS
 SELECT assignment_submission.id,
    assignment_submission.assignment_slug,
    assignment_submission.is_team,
    assignment_submission.user_id,
    assignment_submission.team_nickname,
    assignment_submission.submitter_user_id,
    assignment_submission.created_at,
    assignment_submission.updated_at
   FROM data.assignment_submission;


ALTER TABLE assignment_submissions OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: assignment; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE assignment (
    slug character varying(100) NOT NULL,
    points_possible smallint NOT NULL,
    is_draft boolean DEFAULT true NOT NULL,
    is_markdown boolean DEFAULT false,
    is_team boolean DEFAULT false,
    title character varying(100) NOT NULL,
    body text NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT assignment_points_possible_check CHECK ((points_possible >= 0)),
    CONSTRAINT assignment_slug_check CHECK (((slug)::text ~ '^[a-z0-9-]+'::text)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);



SET search_path = api, pg_catalog;

--
-- Name: assignments; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW assignments AS
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
    ((assignment.is_draft = false) AND (now() < assignment.closed_at)) AS is_open
   FROM data.assignment;


ALTER TABLE assignments OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: engagement; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE engagement (
    user_id integer NOT NULL,
    meeting_id integer NOT NULL,
    participation participation_enum NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);



SET search_path = api, pg_catalog;

--
-- Name: engagements; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW engagements AS
 SELECT engagement.user_id,
    engagement.meeting_id,
    engagement.participation,
    engagement.created_at,
    engagement.updated_at
   FROM data.engagement;


ALTER TABLE engagements OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: meeting; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE meeting (
    id integer NOT NULL,
    title character varying(250) NOT NULL,
    slug character varying(100) NOT NULL,
    summary text,
    description text NOT NULL,
    begins_at timestamp with time zone NOT NULL,
    duration interval NOT NULL,
    is_draft boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT meeting_slug_check CHECK (((slug)::text ~ '^[a-z0-9-]+'::text)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);



SET search_path = api, pg_catalog;

--
-- Name: meetings; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW meetings AS
 SELECT meeting.id,
    meeting.title,
    meeting.slug,
    meeting.summary,
    meeting.description,
    meeting.begins_at,
    meeting.duration,
    meeting.is_draft,
    meeting.created_at,
    meeting.updated_at
   FROM data.meeting;


ALTER TABLE meetings OWNER TO api;

--
-- Name: VIEW meetings; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW meetings IS 'An in-person meeting of our class, usually a lecture';


--
-- Name: COLUMN meetings.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN meetings.id IS 'A surrogate primary key';


--
-- Name: COLUMN meetings.slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN meetings.slug IS 'A short identifier, appropriate for URLs, like "sql-intro"';


--
-- Name: COLUMN meetings.summary; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN meetings.summary IS 'A short description of the meeting in Markdown format';


--
-- Name: COLUMN meetings.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN meetings.description IS 'A long description of the meeting in Markdown format';


--
-- Name: COLUMN meetings.begins_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN meetings.begins_at IS 'The time at which the meeting begins, including timezone';


--
-- Name: COLUMN meetings.duration; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN meetings.duration IS 'The duration of the meeting as a Postgres interval';


--
-- Name: COLUMN meetings.is_draft; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN meetings.is_draft IS 'An indicator of if the content is still changing';


--
-- Name: COLUMN meetings.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN meetings.created_at IS 'The time this database entry was created, including timezone';


--
-- Name: COLUMN meetings.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN meetings.updated_at IS 'The most recent time this database entry was updated, including timezone';


SET search_path = data, pg_catalog;

--
-- Name: quiz_answer; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE quiz_answer (
    quiz_id integer NOT NULL,
    user_id integer NOT NULL,
    quiz_question_option_id integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);



SET search_path = api, pg_catalog;

--
-- Name: quiz_answers; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW quiz_answers AS
 SELECT quiz_answer.quiz_id,
    quiz_answer.user_id,
    quiz_answer.quiz_question_option_id,
    quiz_answer.created_at,
    quiz_answer.updated_at
   FROM data.quiz_answer;


ALTER TABLE quiz_answers OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: quiz_question_option; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE quiz_question_option (
    id integer NOT NULL,
    quiz_question_id integer NOT NULL,
    quiz_id integer NOT NULL,
    body text NOT NULL,
    is_markdown boolean DEFAULT false NOT NULL,
    is_correct boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);



SET search_path = api, pg_catalog;

--
-- Name: quiz_question_options; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW quiz_question_options AS
 SELECT quiz_question_option.id,
    quiz_question_option.quiz_question_id,
    quiz_question_option.quiz_id,
    quiz_question_option.body,
    quiz_question_option.is_markdown,
    quiz_question_option.is_correct,
    quiz_question_option.created_at,
    quiz_question_option.updated_at
   FROM data.quiz_question_option;


ALTER TABLE quiz_question_options OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: quiz_question; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE quiz_question (
    id integer NOT NULL,
    quiz_id integer NOT NULL,
    is_markdown boolean DEFAULT false,
    body text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);



SET search_path = api, pg_catalog;

--
-- Name: quiz_questions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW quiz_questions AS
 SELECT quiz_question.id,
    quiz_question.quiz_id,
    quiz_question.is_markdown,
    quiz_question.body,
    quiz_question.created_at,
    quiz_question.updated_at
   FROM data.quiz_question;


ALTER TABLE quiz_questions OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: quiz_submission; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE quiz_submission (
    quiz_id integer NOT NULL,
    user_id integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);



SET search_path = api, pg_catalog;

--
-- Name: quiz_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW quiz_submissions AS
 SELECT quiz_submission.quiz_id,
    quiz_submission.user_id,
    quiz_submission.created_at,
    quiz_submission.updated_at
   FROM data.quiz_submission;


ALTER TABLE quiz_submissions OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: quiz; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE quiz (
    id integer NOT NULL,
    meeting_id integer NOT NULL,
    points_possible smallint NOT NULL,
    is_draft boolean DEFAULT true NOT NULL,
    duration interval NOT NULL,
    open_at timestamp with time zone NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT closed_after_open CHECK ((closed_at > open_at)),
    CONSTRAINT quiz_points_possible_check CHECK ((points_possible >= 0)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);



SET search_path = api, pg_catalog;

--
-- Name: quizzes; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW quizzes AS
 SELECT quiz.id,
    quiz.meeting_id,
    quiz.points_possible,
    quiz.is_draft,
    quiz.duration,
    quiz.open_at,
    quiz.closed_at,
    quiz.created_at,
    quiz.updated_at,
    ((quiz.is_draft = false) AND (quiz.open_at < now()) AND (now() < quiz.closed_at)) AS is_open
   FROM data.quiz;


ALTER TABLE quizzes OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: team; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE team (
    nickname character varying(50) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at)),
    CONSTRAINT valid_team_nickname CHECK (((nickname)::text ~ '^[\w]{2,20}-[\w]{2,20}$'::text))
);



SET search_path = api, pg_catalog;

--
-- Name: teams; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW teams AS
 SELECT team.nickname,
    team.created_at,
    team.updated_at
   FROM data.team;


ALTER TABLE teams OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: todo; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE todo (
    id integer NOT NULL,
    todo text NOT NULL,
    private boolean DEFAULT true,
    owner_id integer DEFAULT request.user_id()
);



SET search_path = api, pg_catalog;

--
-- Name: todos; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW todos AS
 SELECT todo.id,
    todo.todo,
    todo.private,
    (todo.owner_id = request.user_id()) AS mine
   FROM data.todo;


ALTER TABLE todos OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: ui_element; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE ui_element (
    key character varying(50) NOT NULL,
    body text,
    is_markdown boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ui_element_key_check CHECK (((key)::text ~ '^[a-z0-9\-]+$'::text)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);



SET search_path = api, pg_catalog;

--
-- Name: ui_elements; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW ui_elements AS
 SELECT ui_element.key,
    ui_element.body,
    ui_element.is_markdown,
    ui_element.created_at,
    ui_element.updated_at
   FROM data.ui_element;


ALTER TABLE ui_elements OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: user; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE "user" (
    id integer NOT NULL,
    email character varying(100),
    netid character varying(10) NOT NULL,
    name character varying(100),
    known_as character varying(50),
    nickname character varying(50) NOT NULL,
    role user_role DEFAULT (settings.get('auth.default-role'::text))::user_role NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    team_nickname character varying(50),
    CONSTRAINT user_check CHECK ((updated_at >= created_at)),
    CONSTRAINT user_email_check CHECK (((email)::text ~ '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'::text)),
    CONSTRAINT user_netid_check CHECK (((netid)::text ~ '^[a-z]+[0-9]+$'::text)),
    CONSTRAINT user_nickname_check CHECK (((nickname)::text ~ '^[\w]{2,20}-[\w]{2,20}$'::text))
);



SET search_path = api, pg_catalog;

--
-- Name: users; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW users AS
 SELECT "user".id,
    "user".email,
    "user".netid,
    "user".name,
    "user".known_as,
    "user".nickname,
    "user".role,
    "user".created_at,
    "user".updated_at,
    "user".team_nickname
   FROM data."user";


ALTER TABLE users OWNER TO api;

SET search_path = data, pg_catalog;

--
-- Name: assignment_field_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE assignment_field_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



--
-- Name: assignment_field_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE assignment_field_id_seq OWNED BY assignment_field.id;


--
-- Name: assignment_submission_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE assignment_submission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



--
-- Name: assignment_submission_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE assignment_submission_id_seq OWNED BY assignment_submission.id;


--
-- Name: meeting_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE meeting_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



--
-- Name: meeting_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE meeting_id_seq OWNED BY meeting.id;


--
-- Name: quiz_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE quiz_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



--
-- Name: quiz_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE quiz_id_seq OWNED BY quiz.id;


--
-- Name: quiz_question_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE quiz_question_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



--
-- Name: quiz_question_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE quiz_question_id_seq OWNED BY quiz_question.id;


--
-- Name: quiz_question_option_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE quiz_question_option_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



--
-- Name: quiz_question_option_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE quiz_question_option_id_seq OWNED BY quiz_question_option.id;


--
-- Name: todo_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE todo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



--
-- Name: todo_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE todo_id_seq OWNED BY todo.id;


--
-- Name: user_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

CREATE SEQUENCE user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



--
-- Name: user_id_seq; Type: SEQUENCE OWNED BY; Schema: data; Owner: superuser
--

ALTER SEQUENCE user_id_seq OWNED BY "user".id;


SET search_path = settings, pg_catalog;

--
-- Name: secrets; Type: TABLE; Schema: settings; Owner: superuser
--

CREATE TABLE secrets (
    key text NOT NULL,
    value text NOT NULL
);



SET search_path = data, pg_catalog;

--
-- Name: assignment_field id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_field ALTER COLUMN id SET DEFAULT nextval('assignment_field_id_seq'::regclass);


--
-- Name: assignment_submission id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_submission ALTER COLUMN id SET DEFAULT nextval('assignment_submission_id_seq'::regclass);


--
-- Name: meeting id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY meeting ALTER COLUMN id SET DEFAULT nextval('meeting_id_seq'::regclass);


--
-- Name: quiz id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz ALTER COLUMN id SET DEFAULT nextval('quiz_id_seq'::regclass);


--
-- Name: quiz_question id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_question ALTER COLUMN id SET DEFAULT nextval('quiz_question_id_seq'::regclass);


--
-- Name: quiz_question_option id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_question_option ALTER COLUMN id SET DEFAULT nextval('quiz_question_option_id_seq'::regclass);


--
-- Name: todo id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY todo ALTER COLUMN id SET DEFAULT nextval('todo_id_seq'::regclass);


--
-- Name: user id; Type: DEFAULT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY "user" ALTER COLUMN id SET DEFAULT nextval('user_id_seq'::regclass);


--
-- Name: assignment_field assignment_field_id_assignment_slug_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_field
    ADD CONSTRAINT assignment_field_id_assignment_slug_key UNIQUE (id, assignment_slug);


--
-- Name: assignment_field assignment_field_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_field
    ADD CONSTRAINT assignment_field_pkey PRIMARY KEY (id);


--
-- Name: assignment_field_submission assignment_field_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_pkey PRIMARY KEY (assignment_submission_id, assignment_field_id);


--
-- Name: assignment assignment_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment
    ADD CONSTRAINT assignment_pkey PRIMARY KEY (slug);


--
-- Name: assignment assignment_slug_is_team_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment
    ADD CONSTRAINT assignment_slug_is_team_key UNIQUE (slug, is_team);


--
-- Name: assignment_submission assignment_submission_id_assignment_slug_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_submission
    ADD CONSTRAINT assignment_submission_id_assignment_slug_key UNIQUE (id, assignment_slug);


--
-- Name: assignment_submission assignment_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_submission
    ADD CONSTRAINT assignment_submission_pkey PRIMARY KEY (id);


--
-- Name: engagement engagement_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY engagement
    ADD CONSTRAINT engagement_pkey PRIMARY KEY (user_id, meeting_id);


--
-- Name: meeting meeting_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY meeting
    ADD CONSTRAINT meeting_pkey PRIMARY KEY (id);


--
-- Name: meeting meeting_slug_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY meeting
    ADD CONSTRAINT meeting_slug_key UNIQUE (slug);


--
-- Name: quiz_answer quiz_answer_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_answer
    ADD CONSTRAINT quiz_answer_pkey PRIMARY KEY (quiz_id, user_id, quiz_question_option_id);


--
-- Name: quiz quiz_meeting_id_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz
    ADD CONSTRAINT quiz_meeting_id_key UNIQUE (meeting_id);


--
-- Name: quiz quiz_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz
    ADD CONSTRAINT quiz_pkey PRIMARY KEY (id);


--
-- Name: quiz_question quiz_question_id_quiz_id_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_question
    ADD CONSTRAINT quiz_question_id_quiz_id_key UNIQUE (id, quiz_id);


--
-- Name: quiz_question_option quiz_question_option_id_quiz_id_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_question_option
    ADD CONSTRAINT quiz_question_option_id_quiz_id_key UNIQUE (id, quiz_id);


--
-- Name: quiz_question_option quiz_question_option_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_question_option
    ADD CONSTRAINT quiz_question_option_pkey PRIMARY KEY (id);


--
-- Name: quiz_question quiz_question_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_question
    ADD CONSTRAINT quiz_question_pkey PRIMARY KEY (id);


--
-- Name: quiz_submission quiz_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_submission
    ADD CONSTRAINT quiz_submission_pkey PRIMARY KEY (quiz_id, user_id);


--
-- Name: team team_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY team
    ADD CONSTRAINT team_pkey PRIMARY KEY (nickname);


--
-- Name: todo todo_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY todo
    ADD CONSTRAINT todo_pkey PRIMARY KEY (id);


--
-- Name: ui_element ui_element_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY ui_element
    ADD CONSTRAINT ui_element_pkey PRIMARY KEY (key);


--
-- Name: user user_email_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY "user"
    ADD CONSTRAINT user_email_key UNIQUE (email);


--
-- Name: user user_netid_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY "user"
    ADD CONSTRAINT user_netid_key UNIQUE (netid);


--
-- Name: user user_nickname_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY "user"
    ADD CONSTRAINT user_nickname_key UNIQUE (nickname);


--
-- Name: user user_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY "user"
    ADD CONSTRAINT user_pkey PRIMARY KEY (id);


SET search_path = settings, pg_catalog;

--
-- Name: secrets secrets_pkey; Type: CONSTRAINT; Schema: settings; Owner: superuser
--

ALTER TABLE ONLY secrets
    ADD CONSTRAINT secrets_pkey PRIMARY KEY (key);


SET search_path = data, pg_catalog;

--
-- Name: assignment_submission_unique_team; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX assignment_submission_unique_team ON assignment_submission USING btree (team_nickname, assignment_slug) WHERE (user_id IS NULL);


--
-- Name: assignment_submission_unique_user; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX assignment_submission_unique_user ON assignment_submission USING btree (user_id, assignment_slug) WHERE (team_nickname IS NULL);


--
-- Name: todo send_change_event; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER send_change_event AFTER INSERT OR DELETE OR UPDATE ON todo FOR EACH ROW EXECUTE PROCEDURE rabbitmq.on_row_change();


--
-- Name: assignment tg_assignment_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_default BEFORE INSERT OR UPDATE ON assignment FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();


--
-- Name: assignment_field_submission tg_assignment_field_submission_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_field_submission_default BEFORE INSERT OR UPDATE ON assignment_field_submission FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();


--
-- Name: assignment_submission tg_assignment_submission_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_submission_default BEFORE INSERT OR UPDATE ON assignment_submission FOR EACH ROW EXECUTE PROCEDURE fill_assignment_submission_defaults();


--
-- Name: engagement tg_engagement_update_timestamps; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_engagement_update_timestamps BEFORE INSERT OR UPDATE ON engagement FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();


--
-- Name: meeting tg_meeting_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_meeting_default BEFORE INSERT OR UPDATE ON meeting FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();


--
-- Name: quiz_answer tg_quiz_answer_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_answer_default BEFORE INSERT OR UPDATE ON quiz_answer FOR EACH ROW EXECUTE PROCEDURE fill_answer_defaults();


--
-- Name: quiz tg_quiz_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_default BEFORE INSERT OR UPDATE ON quiz FOR EACH ROW EXECUTE PROCEDURE quiz_set_defaults();


--
-- Name: quiz_question tg_quiz_question_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_question_default BEFORE INSERT OR UPDATE ON quiz_question FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();


--
-- Name: quiz_question_option tg_quiz_question_option_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_question_option_default BEFORE INSERT OR UPDATE ON quiz_question_option FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();


--
-- Name: quiz_submission tg_quiz_submission_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_submission_default BEFORE INSERT OR UPDATE ON quiz_submission FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();


--
-- Name: team tg_team_update_timestamps; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_team_update_timestamps BEFORE INSERT OR UPDATE ON team FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();


--
-- Name: ui_element tg_ui_element_update_timestamps; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_ui_element_update_timestamps BEFORE INSERT OR UPDATE ON ui_element FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();


--
-- Name: user tg_users_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_users_default BEFORE INSERT OR UPDATE ON "user" FOR EACH ROW EXECUTE PROCEDURE clean_user_fields();


--
-- Name: assignment_field assignment_field_assignment_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_field
    ADD CONSTRAINT assignment_field_assignment_slug_fkey FOREIGN KEY (assignment_slug) REFERENCES assignment(slug);


--
-- Name: assignment_field_submission assignment_field_submission_assignment_field_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_assignment_field_id_fkey FOREIGN KEY (assignment_field_id, assignment_slug) REFERENCES assignment_field(id, assignment_slug) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: assignment_field_submission assignment_field_submission_assignment_submission_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_assignment_submission_id_fkey FOREIGN KEY (assignment_submission_id, assignment_slug) REFERENCES assignment_submission(id, assignment_slug) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: assignment_field_submission assignment_field_submission_submitter_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_submitter_user_id_fkey FOREIGN KEY (submitter_user_id) REFERENCES "user"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: assignment_submission assignment_submission_assignment_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_submission
    ADD CONSTRAINT assignment_submission_assignment_slug_fkey FOREIGN KEY (assignment_slug, is_team) REFERENCES assignment(slug, is_team);


--
-- Name: assignment_submission assignment_submission_submitter_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_submission
    ADD CONSTRAINT assignment_submission_submitter_user_id_fkey FOREIGN KEY (submitter_user_id) REFERENCES "user"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: assignment_submission assignment_submission_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_submission
    ADD CONSTRAINT assignment_submission_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES team(nickname) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: assignment_submission assignment_submission_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY assignment_submission
    ADD CONSTRAINT assignment_submission_user_id_fkey FOREIGN KEY (user_id) REFERENCES "user"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: engagement engagement_meeting_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY engagement
    ADD CONSTRAINT engagement_meeting_id_fkey FOREIGN KEY (meeting_id) REFERENCES meeting(id) ON DELETE CASCADE;


--
-- Name: engagement engagement_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY engagement
    ADD CONSTRAINT engagement_user_id_fkey FOREIGN KEY (user_id) REFERENCES "user"(id) ON DELETE CASCADE;


--
-- Name: quiz_answer quiz_answer_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_answer
    ADD CONSTRAINT quiz_answer_quiz_id_fkey FOREIGN KEY (quiz_id, user_id) REFERENCES quiz_submission(quiz_id, user_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quiz_answer quiz_answer_quiz_question_option_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_answer
    ADD CONSTRAINT quiz_answer_quiz_question_option_id_fkey FOREIGN KEY (quiz_question_option_id, quiz_id) REFERENCES quiz_question_option(id, quiz_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quiz quiz_meeting_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz
    ADD CONSTRAINT quiz_meeting_id_fkey FOREIGN KEY (meeting_id) REFERENCES meeting(id) ON DELETE CASCADE;


--
-- Name: quiz_question_option quiz_question_option_quiz_question_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_question_option
    ADD CONSTRAINT quiz_question_option_quiz_question_id_fkey FOREIGN KEY (quiz_question_id, quiz_id) REFERENCES quiz_question(id, quiz_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quiz_question quiz_question_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_question
    ADD CONSTRAINT quiz_question_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES quiz(id) ON DELETE CASCADE;


--
-- Name: quiz_submission quiz_submission_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_submission
    ADD CONSTRAINT quiz_submission_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES quiz(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: quiz_submission quiz_submission_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY quiz_submission
    ADD CONSTRAINT quiz_submission_user_id_fkey FOREIGN KEY (user_id) REFERENCES "user"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: todo todo_owner_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY todo
    ADD CONSTRAINT todo_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES "user"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: user user_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY "user"
    ADD CONSTRAINT user_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES team(nickname) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE assignment_field_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_field_submission assignment_field_submission_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_field_submission_access_policy ON assignment_field_submission TO api USING ((((request.user_role() = 'student'::text) AND ((submitter_user_id = request.user_id()) OR (EXISTS ( SELECT ass_sub.id,
    ass_sub.assignment_slug,
    ass_sub.is_team,
    ass_sub.user_id,
    ass_sub.team_nickname,
    ass_sub.submitter_user_id,
    ass_sub.created_at,
    ass_sub.updated_at,
    users.id,
    users.email,
    users.netid,
    users.name,
    users.known_as,
    users.nickname,
    users.role,
    users.created_at,
    users.updated_at,
    users.team_nickname
   FROM (api.assignment_submissions ass_sub
     JOIN api.users ON (((ass_sub.user_id = users.id) OR ((ass_sub.team_nickname)::text = (users.team_nickname)::text))))
  WHERE ((users.id = request.user_id()) AND (ass_sub.id = assignment_field_submission.assignment_submission_id)))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = 'student'::text) AND ((submitter_user_id = request.user_id()) AND (EXISTS ( SELECT ass_sub.id,
    ass_sub.assignment_slug,
    ass_sub.is_team,
    ass_sub.user_id,
    ass_sub.team_nickname,
    ass_sub.submitter_user_id,
    ass_sub.created_at,
    ass_sub.updated_at,
    users.id,
    users.email,
    users.netid,
    users.name,
    users.known_as,
    users.nickname,
    users.role,
    users.created_at,
    users.updated_at,
    users.team_nickname,
    assignments.slug,
    assignments.points_possible,
    assignments.is_draft,
    assignments.is_markdown,
    assignments.is_team,
    assignments.title,
    assignments.body,
    assignments.closed_at,
    assignments.created_at,
    assignments.updated_at,
    assignments.is_open
   FROM ((api.assignment_submissions ass_sub
     JOIN api.users ON (((ass_sub.user_id = users.id) OR ((ass_sub.team_nickname)::text = (users.team_nickname)::text))))
     JOIN api.assignments ON (((assignments.slug)::text = (ass_sub.assignment_slug)::text)))
  WHERE ((assignments.is_open = true) AND (users.id = request.user_id()) AND (ass_sub.id = assignment_field_submission.assignment_submission_id))))))));


--
-- Name: assignment_submission; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE assignment_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_submission assignment_submission_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_submission_access_policy ON assignment_submission TO api USING ((((request.user_role() = 'student'::text) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (EXISTS ( SELECT u.id,
    u.email,
    u.netid,
    u.name,
    u.known_as,
    u.nickname,
    u.role,
    u.created_at,
    u.updated_at,
    u.team_nickname
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND ((u.team_nickname)::text = (assignment_submission.team_nickname)::text))))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = 'student'::text) AND (EXISTS ( SELECT a.slug,
    a.points_possible,
    a.is_draft,
    a.is_markdown,
    a.is_team,
    a.title,
    a.body,
    a.closed_at,
    a.created_at,
    a.updated_at,
    a.is_open
   FROM api.assignments a
  WHERE (((a.slug)::text = (assignment_submission.assignment_slug)::text) AND a.is_open))) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (EXISTS ( SELECT u.id,
    u.email,
    u.netid,
    u.name,
    u.known_as,
    u.nickname,
    u.role,
    u.created_at,
    u.updated_at,
    u.team_nickname
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND ((u.team_nickname)::text = (assignment_submission.team_nickname)::text)))))))));


--
-- Name: engagement; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE engagement ENABLE ROW LEVEL SECURITY;

--
-- Name: engagement engagement_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY engagement_access_policy ON engagement TO api USING ((((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text)));


--
-- Name: quiz_answer; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE quiz_answer ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_answer quiz_answer_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_answer_access_policy ON quiz_answer TO api USING ((((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = 'student'::text) AND (request.user_id() = user_id) AND (EXISTS ( SELECT q.id,
    q.meeting_id,
    q.points_possible,
    q.is_draft,
    q.duration,
    q.open_at,
    q.closed_at,
    q.created_at,
    q.updated_at,
    q.is_open
   FROM api.quizzes q
  WHERE ((q.id = quiz_answer.quiz_id) AND q.is_open))))));


--
-- Name: quiz_question; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE quiz_question ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_question quiz_question_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_question_access_policy ON quiz_question TO api USING ((((request.user_role() = 'student'::text) AND (EXISTS ( SELECT qs.quiz_id,
    qs.user_id,
    qs.created_at,
    qs.updated_at
   FROM api.quiz_submissions qs
  WHERE ((qs.user_id = request.user_id()) AND (quiz_question.quiz_id = qs.quiz_id))))) OR (request.user_role() = 'faculty'::text)));


--
-- Name: quiz_question_option; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE quiz_question_option ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_question_option quiz_question_option_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_question_option_access_policy ON quiz_question_option TO api USING ((((request.user_role() = 'student'::text) AND (EXISTS ( SELECT qs.quiz_id,
    qs.user_id,
    qs.created_at,
    qs.updated_at
   FROM api.quiz_submissions qs
  WHERE ((qs.user_id = request.user_id()) AND (quiz_question_option.quiz_id = qs.quiz_id))))) OR (request.user_role() = 'faculty'::text)));


--
-- Name: quiz_submission; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE quiz_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_submission quiz_submission_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_submission_access_policy ON quiz_submission TO api USING ((((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = 'student'::text) AND ((request.user_id() = user_id) AND (EXISTS ( SELECT q.id,
    q.meeting_id,
    q.points_possible,
    q.is_draft,
    q.duration,
    q.open_at,
    q.closed_at,
    q.created_at,
    q.updated_at,
    q.is_open
   FROM api.quizzes q
  WHERE ((q.id = quiz_submission.quiz_id) AND q.is_open)))))));


--
-- Name: team; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE team ENABLE ROW LEVEL SECURITY;

--
-- Name: team team_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY team_access_policy ON team TO api USING ((((request.user_role() = 'student'::text) AND ((nickname)::text = (( SELECT users.team_nickname
   FROM api.users
  WHERE (users.id = request.user_id())))::text)) OR (request.user_role() = 'faculty'::text)));


--
-- Name: todo; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE todo ENABLE ROW LEVEL SECURITY;

--
-- Name: todo todo_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY todo_access_policy ON todo TO api USING ((((request.user_role() = 'student'::text) AND (request.user_id() = owner_id)) OR (private = false))) WITH CHECK (((request.user_role() = 'student'::text) AND (request.user_id() = owner_id)));


--
-- Name: user; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE "user" ENABLE ROW LEVEL SECURITY;

--
-- Name: user user_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY user_access_policy ON "user" TO api USING ((((request.user_role() = 'student'::text) AND (request.user_id() = id)) OR ((request.user_role() = 'faculty'::text) OR ("current_user"() = 'authapp'::name))));


--
-- Name: api; Type: ACL; Schema: -; Owner: superuser
--

GRANT USAGE ON SCHEMA api TO anonymous;
GRANT USAGE ON SCHEMA api TO student;
GRANT USAGE ON SCHEMA api TO faculty;
GRANT USAGE ON SCHEMA api TO authapp;


--
-- Name: rabbitmq; Type: ACL; Schema: -; Owner: superuser
--

GRANT USAGE ON SCHEMA rabbitmq TO PUBLIC;


--
-- Name: request; Type: ACL; Schema: -; Owner: superuser
--

GRANT USAGE ON SCHEMA request TO PUBLIC;


--
-- Name: assignment_field_submission; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE assignment_field_submission TO api;


SET search_path = api, pg_catalog;

--
-- Name: assignment_field_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT,UPDATE ON TABLE assignment_field_submissions TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE assignment_field_submissions TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: assignment_field; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE assignment_field TO api;


SET search_path = api, pg_catalog;

--
-- Name: assignment_fields; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE assignment_fields TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE assignment_fields TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: assignment_submission; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE assignment_submission TO api;


SET search_path = api, pg_catalog;

--
-- Name: assignment_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT ON TABLE assignment_submissions TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE assignment_submissions TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: assignment; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE assignment TO api;


SET search_path = api, pg_catalog;

--
-- Name: assignments; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE assignments TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE assignments TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: engagement; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engagement TO api;


SET search_path = api, pg_catalog;

--
-- Name: engagements; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE engagements TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE engagements TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: meeting; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE meeting TO api;


SET search_path = api, pg_catalog;

--
-- Name: meetings; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE meetings TO student;
GRANT SELECT ON TABLE meetings TO anonymous;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE meetings TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: quiz_answer; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE quiz_answer TO api;


SET search_path = api, pg_catalog;

--
-- Name: quiz_answers; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT,DELETE ON TABLE quiz_answers TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE quiz_answers TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: quiz_question_option; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE quiz_question_option TO api;


SET search_path = api, pg_catalog;

--
-- Name: quiz_question_options; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE quiz_question_options TO faculty;


--
-- Name: quiz_question_options.id; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(id) ON TABLE quiz_question_options TO student;


--
-- Name: quiz_question_options.quiz_question_id; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(quiz_question_id) ON TABLE quiz_question_options TO student;


--
-- Name: quiz_question_options.quiz_id; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(quiz_id) ON TABLE quiz_question_options TO student;


--
-- Name: quiz_question_options.body; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(body) ON TABLE quiz_question_options TO student;


--
-- Name: quiz_question_options.is_markdown; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(is_markdown) ON TABLE quiz_question_options TO student;


--
-- Name: quiz_question_options.created_at; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(created_at) ON TABLE quiz_question_options TO student;


--
-- Name: quiz_question_options.updated_at; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(updated_at) ON TABLE quiz_question_options TO student;


SET search_path = data, pg_catalog;

--
-- Name: quiz_question; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE quiz_question TO api;


SET search_path = api, pg_catalog;

--
-- Name: quiz_questions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE quiz_questions TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE quiz_questions TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: quiz_submission; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE quiz_submission TO api;


SET search_path = api, pg_catalog;

--
-- Name: quiz_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT ON TABLE quiz_submissions TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE quiz_submissions TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: quiz; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE quiz TO api;


SET search_path = api, pg_catalog;

--
-- Name: quizzes; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE quizzes TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE quizzes TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: team; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE team TO api;


SET search_path = api, pg_catalog;

--
-- Name: teams; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE teams TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE teams TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: todo; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE todo TO api;


SET search_path = api, pg_catalog;

--
-- Name: todos; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE todos TO student;


--
-- Name: todos.id; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(id) ON TABLE todos TO anonymous;


--
-- Name: todos.todo; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT(todo) ON TABLE todos TO anonymous;


SET search_path = data, pg_catalog;

--
-- Name: ui_element; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE ui_element TO api;


SET search_path = api, pg_catalog;

--
-- Name: ui_elements; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE ui_elements TO student;
GRANT SELECT ON TABLE ui_elements TO anonymous;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE ui_elements TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: user; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "user" TO api;


SET search_path = api, pg_catalog;

--
-- Name: users; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE users TO student;
GRANT SELECT ON TABLE users TO authapp;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE users TO faculty;


SET search_path = data, pg_catalog;

--
-- Name: assignment_field_id_seq; Type: ACL; Schema: data; Owner: superuser
--

GRANT USAGE ON SEQUENCE assignment_field_id_seq TO faculty;


--
-- Name: assignment_submission_id_seq; Type: ACL; Schema: data; Owner: superuser
--

GRANT USAGE ON SEQUENCE assignment_submission_id_seq TO faculty;
GRANT USAGE ON SEQUENCE assignment_submission_id_seq TO student;


--
-- Name: meeting_id_seq; Type: ACL; Schema: data; Owner: superuser
--

GRANT USAGE ON SEQUENCE meeting_id_seq TO student;
GRANT USAGE ON SEQUENCE meeting_id_seq TO faculty;


--
-- Name: quiz_id_seq; Type: ACL; Schema: data; Owner: superuser
--

GRANT USAGE ON SEQUENCE quiz_id_seq TO student;
GRANT USAGE ON SEQUENCE quiz_id_seq TO faculty;


--
-- Name: quiz_question_id_seq; Type: ACL; Schema: data; Owner: superuser
--

GRANT USAGE ON SEQUENCE quiz_question_id_seq TO student;
GRANT USAGE ON SEQUENCE quiz_question_id_seq TO faculty;


--
-- Name: quiz_question_option_id_seq; Type: ACL; Schema: data; Owner: superuser
--

GRANT USAGE ON SEQUENCE quiz_question_option_id_seq TO student;
GRANT USAGE ON SEQUENCE quiz_question_option_id_seq TO faculty;


--
-- Name: todo_id_seq; Type: ACL; Schema: data; Owner: superuser
--

GRANT USAGE ON SEQUENCE todo_id_seq TO student;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: -; Owner: api
--

ALTER DEFAULT PRIVILEGES FOR ROLE api REVOKE ALL ON FUNCTIONS  FROM PUBLIC;


--
-- PostgreSQL database dump complete
--

