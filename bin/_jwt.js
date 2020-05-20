/* eslint-disable no-console */
const jwt = require('jsonwebtoken');

if (process.argv.length !== 3) {
    console.error('Invalid number or arguments, expected one!');
    console.log(process.argv);
    process.exit(1);
}

const payload = JSON.parse(process.argv[2]);
payload.iat = Math.floor(Date.now() / 1000) - 30;
const token = jwt.sign(payload, process.env.JWT_SECRET);
console.log(token);
