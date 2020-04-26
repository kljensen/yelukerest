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

// Grab the jwt secret, used for signing JWTs
config.jwt_secret = getRequiredEnvVariable('JWT_SECRET');
config.jwt_issuer = 'yeluke-authapp';

// Get database-related connection info
config.db_host = getRequiredEnvVariable('DB_HOST');
config.db_port = getRequiredEnvVariable('DB_PORT');
config.db_schema = getRequiredEnvVariable('DB_SCHEMA');
config.db_name = getRequiredEnvVariable('DB_NAME');
config.db_user = getRequiredEnvVariable('DB_USER');
config.db_pass = getRequiredEnvVariable('DB_PASS');

// Grab the host and port on which we should run
config.host = '0.0.0.0';
config.port = getRequiredEnvVariable('PORT');

module.exports = config;
