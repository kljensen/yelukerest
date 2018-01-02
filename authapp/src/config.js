// Here, we are grabbing all the information
// we need from the environment and putting it
// into an object.

const config = {};

/**
 * @param  {String} varName The environment variable in which the value resides
 * @returns {undefined}
 */
function getRequiredEnvVariable(varName) {
    const value = process.env[varName];
    if (!value) {
        throw new Error(`You must supply a ${varName} environment variable`);
    }
    return value;
}

// The "DEVELOPMENT" environment variable is passed
// into the docker container.
if (process.env.DEVELOPMENT) {
    config.is_development = true;
    config.is_production = false;
} else {
    config.is_development = false;
    config.is_production = true;
}

// Grab the CAS host
config.cas_host = getRequiredEnvVariable('CAS_HOST');
if (config.is_production) {
    config.cas_protocol = 'https';
} else {
    config.cas_protocol = process.env.CAS_PROTOCOL || 'https';
    // If we're running in a testing environment in docker containers,
    // the service validation cas host might not be routable through
    // the same host as the cas_host. Used for testing only!
    config.cas_service_validate_host = process.env.CAS_SERVICE_VALIDATE_HOST;
}

// Grab Redis host and port
config.redis_host = getRequiredEnvVariable('REDIS_HOST');
config.redis_port = getRequiredEnvVariable('REDIS_PORT');

// Grab the session secret, used for signing cookies
config.session_secret = getRequiredEnvVariable('SESSION_SECRET');

// Get database-related connection info
config.db_host = getRequiredEnvVariable('DB_HOST');
config.db_port = getRequiredEnvVariable('DB_PORT');
config.db_schema = getRequiredEnvVariable('DB_SCHEMA');
config.db_name = getRequiredEnvVariable('DB_NAME');
config.db_user = getRequiredEnvVariable('DB_USER');
config.db_pass = getRequiredEnvVariable('DB_PASS');

// Grab the host and port on which we should run
config.host = '0.0.0.0';
config.port = process.env.AUTHAPP_PORT || '4000';

if (config.is_development) {
    console.log('Configuration:');
    console.log(config);
}

module.exports = config;
