# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Development
- **Start development environment**: `./bin/dev.sh up` (starts all containers using docker-compose.base.yaml + docker-compose.dev.yaml)
- **Stop development environment**: `./bin/dev.sh down`
- **Connect to development database**: `./bin/connect_to.sh` or use the `pg_connect.sh` script

### Production
- **Start production environment**: `./bin/prod.sh up` (uses docker-compose.base.yaml + docker-compose.prod.yaml)
- **Stop production environment**: `./bin/prod.sh down`

### Database Operations
- **Reset database**: `./bin/reset_db.sh` (resets database to initial state with sample data)
- **Run migrations**: `./bin/migrate.sh [development|production]` (Zapadka verifies by default)
- **Connect to database**: `./bin/pg_connect.sh`
- **Dump database**: `./bin/dumpdb.sh`

### Testing
- **Run all tests**: `bun run test` (runs both database and REST API tests)
- **Run database tests only**: `bun run test_db` (Zapadka structured SQL tests)
- **Run REST API tests only**: `bun run test_rest` (uses Bun test + Supertest)

### Development Utilities
- **Generate JWT tokens**: `./bin/jwt.sh '{"role": "student"}'`
- **Create migration**: `zapadka new add-[change]` (or `./bin/new-table.sh [table]`)

## Architecture

Yelukerest is a class management system built around PostgreSQL with PostgREST providing an HTTP API. The architecture follows a database-centric approach where most business logic is implemented in PostgreSQL using row-level security and declarative constraints.

### Core Components

**Database Layer (`db/src/`)**
- **`data/yeluke/`**: Table definitions and core data structures
- **`api/yeluke/`**: API views and functions exposed through PostgREST
- **`authorization/yeluke/`**: Row-level security policies and permissions
- **`sample_data/yeluke/`**: Sample data for development/testing
- **`libs/`**: Shared database libraries (auth, pgjwt, settings, request context)

**Services (Docker containers)**
- **`postgrest`**: Auto-generates REST API from PostgreSQL schema
- **`db`**: PostgreSQL database with all business logic
- **`elmclient`**: Elm-based web frontend for students/faculty
- **`authapp`**: Go-based CAS authentication service  
- **`caddy`**: Reverse proxy and web server

**Client Applications**
- **`elmclient/`**: Main web interface (Elm compiled directly to static files)
- **`pythonclient/`**: CLI tool for bulk administration operations

### Key Database Tables
- **`user`**: Students, faculty, staff with role-based access
- **`meeting`**: Class meeting times and subjects
- **`engagement`**: Student participation tracking
- **`quiz`** + **`quiz_submission`** + **`quiz_grade`**: Paper quiz metadata, submissions, and grades
- **`assignment`** + **`assignment_field`** + **`assignment_submission`**: Assignment management
- **`grade`**: Grade calculations and distributions
- **`team`**: Group/team management

### Development Workflow

1. Deployable schema changes live in a new Zapadka migration under `migrations/`; provide `deploy.sql` and `verify.sql`, and `revert.sql` when reversible. Run `zapadka lint`, deploy to a disposable target, then run `bun run test_db`.

2. `db/src/` is the immutable-bootstrap input and test fixtures. Do not add deployable schema changes there.

3. All API access goes through PostgREST which enforces PostgreSQL's row-level security

### Environment Configuration

The system requires a `.env` file with database credentials, JWT secrets, and service configuration. Key variables include `DB_*` for database connection, `JWT_SECRET` for authentication, and various service-specific ports and URLs.
