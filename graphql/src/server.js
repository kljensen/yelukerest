const config = require('./config.js');
const express = require('express');

console.log('woot');
const app = express();

app.get('/', (_req, res) => {
    res.send('Hello world!');
});

app.listen(config.port, () => {
    console.log(`listening on port ${config.port}`);
});
