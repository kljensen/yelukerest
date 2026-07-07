const config = require('dotenv')
    .config;
const spawnSync = require('child_process')
    .spawnSync;
// var execSync = require('child_process').execSync;
const jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VyX2lkIjoxLCJyb2xlIjoid2VidXNlciJ9.uSsS2cukBlM6QXe4Y0H90fsdkJSGcle9b7p_kMV1Ymk'
const request = require('supertest');

config(); //.env file vars added to process.env
const COMPOSE_PROJECT_NAME = process.env.COMPOSE_PROJECT_NAME;
const POSTGRES_USER = process.env.POSTGRES_USER;
const POSTGRES_PASSWORD = process.env.POSTGRES_PASSWORD;
const SUPER_USER = process.env.SUPER_USER;
const SUPER_USER_PASSWORD = process.env.SUPER_USER_PASSWORD;

const DB_HOST = process.env.DB_TEST_HOST || 'localhost';
const DB_PORT = process.env.DB_TEST_PORT || process.env.DB_PORT || '5432';
const DB_NAME = process.env.DB_NAME;

const psql_version = spawnSync('sh', ['-c', 'command -v psql']);
const psql_path = psql_version.status === 0 ? psql_version.stdout.toString('utf8').trim() : '';
const have_psql = psql_path.length > 0;

const streamToString = (stream) => {
    if (!stream) {
        return '';
    }
    return stream.toString('utf8');
};

const baseURL = 'https://localhost';
// So that we don't raise an error on self-signed certs.
process.env["NODE_TLS_REJECT_UNAUTHORIZED"] = 0;
var restService = function () {
    return request(`${baseURL}/rest`);
}

const resetdb = () => {
    let pg;
    if (have_psql) {
        var env = Object.create(process.env);
        env.PGPASSWORD = SUPER_USER_PASSWORD
        pg = spawnSync(psql_path, ['-h', DB_HOST, '-p', DB_PORT, '-U', SUPER_USER, DB_NAME, '-f', `${process.cwd()}/db/src/sample_data/reset.sql`], {
            env: env
        });
    } else {
        pg = spawnSync('docker', ['compose', '-f', 'docker-compose.base.yaml', '-f', 'docker-compose.dev.yaml', 'exec', '-T', 'db', 'psql', '-U', SUPER_USER, DB_NAME, '-f', 'docker-entrypoint-initdb.d/sample_data/reset.sql'])
    }
    if (pg.status !== 0) {
        throw new Error(`Could not reset database in rest tests. Error = ${streamToString(pg.stderr)}${streamToString(pg.stdout)}${pg.error || ''}`);
    }
}

module.exports = {
    jwt,
    resetdb,
    restService,
    baseURL,
    authPath: '/auth/login',
    jwtPath: '/auth/jwt',
}
