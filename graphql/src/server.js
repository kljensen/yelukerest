const config = require('./config.js');

const express = require('express');
const { postgraphile } = require('postgraphile');

const app = express();

const pg = postgraphile(
    config.database_url,
    'api',
    // config.database_schema,
    config.postgraphile_options,
);

app.use(pg);

app.listen(config.port, () => {
    // eslint-disable-next-line no-console
    console.log(`listening on port ${config.port}`);
    console.log(`database url = ${config.database_url}`);
    console.log(config.postgraphile_options);
});
