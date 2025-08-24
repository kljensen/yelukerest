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
- **Run migrations**: `./bin/migrate.sh`
- **Connect to database**: `./bin/pg_connect.sh`
- **Dump database**: `./bin/dumpdb.sh`

### Testing
- **Run all tests**: `npm test` (runs both database and REST API tests)
- **Run database tests only**: `npm run test_db` (uses pgTAP for PostgreSQL testing)
- **Run REST API tests only**: `npm run test_rest` (uses Mocha + Supertest)

### Development Utilities
- **Generate JWT tokens**: `./bin/jwt.sh '{"role": "student"}'`
- **Create new table**: `./bin/new-table.sh [tablename]` (scaffolds new table files)

## Architecture

Yelukerest is a class management system built around PostgreSQL with PostgREST providing a RESTful API. The architecture follows a database-centric approach where most business logic is implemented in PostgreSQL using row-level security and declarative constraints.

### Core Components

**Database Layer (`db/src/`)**
- **`data/yeluke/`**: Table definitions and core data structures
- **`api/yeluke/`**: API views and functions exposed through PostgREST
- **`authorization/yeluke/`**: Row-level security policies and permissions
- **`sample_data/yeluke/`**: Sample data for development/testing
- **`libs/`**: Shared database libraries (auth, pgjwt, rabbitmq integration)

**Services (Docker containers)**
- **`postgrest`**: Auto-generates REST API from PostgreSQL schema
- **`db`**: PostgreSQL database with all business logic
- **`elmclient`**: Elm-based web frontend for students/faculty
- **`authapp`**: Go-based CAS authentication service  
- **`sse`**: Server-sent events service for real-time updates
- **`caddy`**: Reverse proxy and web server
- **`rabbitmq`**: Message broker for database notifications
- **`pg_amqp_bridge`**: Forwards PostgreSQL NOTIFY events to RabbitMQ

**Client Applications**
- **`elmclient/`**: Main web interface (Elm + Webpack)
- **`pythonclient/`**: CLI tool for bulk administration operations

### Key Database Tables
- **`user`**: Students, faculty, staff with role-based access
- **`meeting`**: Class meeting times and subjects
- **`engagement`**: Student participation tracking
- **`quiz`** + **`quiz_question`** + **`quiz_answer`**: Quiz system
- **`assignment`** + **`assignment_field`** + **`assignment_submission`**: Assignment management
- **`grade`**: Grade calculations and distributions
- **`team`**: Group/team management

### Development Workflow

1. Database changes require updates to multiple files:
   - Add table: `db/src/data/yeluke/[table].sql`
   - Add API views: `db/src/api/yeluke/[table].sql` 
   - Add authorization: `db/src/authorization/yeluke/[table].sql`
   - Add sample data: `db/src/sample_data/yeluke/[table].sql`
   - Add tests: `tests/db/yeluke-[table].sql`

2. The system uses Sqitch for database migrations (`db/migrations/`)

3. All API access goes through PostgREST which enforces PostgreSQL's row-level security

4. Real-time updates flow: PostgreSQL NOTIFY → pg_amqp_bridge → RabbitMQ → SSE → Elm frontend

### Environment Configuration

The system requires a `.env` file with database credentials, JWT secrets, and service configuration. Key variables include `DB_*` for database connection, `JWT_SECRET` for authentication, and various service-specific ports and URLs.