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
config.database_url = getRequiredEnvVariable('DATABASE_URL');
config.database_schema = getRequiredEnvVariable('DATABASE_SCHEMA');

// Grab the host and port on which we should run
config.host = '0.0.0.0';
config.port = getRequiredEnvVariable('PORT');

if (config.is_development) {
    config.postgraphile_options = {
        // subscriptions: false,
        watchPg: false,
        // dynamicJson: true,
        setofFunctionsContainNulls: false,
        ignoreRBAC: false,
        ignoreIndexes: false,
        showErrorStack: 'json',
        // extendedErrors: ['hint', 'detail', 'errcode'],
        extendedErrors: [
            'severity',
            'code',
            'detail',
            'hint',
            'position',
            'internalPosition',
            'internalQuery',
            'where',
            'schema',
            'table',
            'column',
            'dataType',
            'constraint',
            'file',
            'line',
            'routine',
        ],
        appendPlugins: [require('@graphile-contrib/pg-simplify-inflector')],
        exportGqlSchemaPath: 'schema.graphql',
        graphiql: true,
        enhanceGraphiql: true,
        graphiqlRoute: '/foo',
        enableQueryBatching: true,
        legacyRelations: 'omit',
        // allowExplain(req) {
        //     // TODO: customise condition!
        //     return true;
        // },
        // pgSettings(req) {
        //     /* TODO */
        // },
    };
} else {
    config.postgraphile_options = {
        subscriptions: true,
        retryOnInitFail: true,
        // dynamicJson: true,
        setofFunctionsContainNulls: false,
        ignoreRBAC: false,
        ignoreIndexes: false,
        extendedErrors: ['errcode'],
        // appendPlugins: [require('@graphile-contrib/pg-simplify-inflector')],
        graphiql: false,
        enableQueryBatching: true,
        // our default logging has performance issues, but do make sure
        // you have a logging system in place!
        disableQueryLog: true,
        legacyRelations: 'omit',
    };
}

module.exports = config;
