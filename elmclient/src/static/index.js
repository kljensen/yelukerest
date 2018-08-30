/* eslint-env browser */
/* global PIAZZA_URL COURSE_TITLE ABOUT_URL CANVAS_URL */
// pull in desired CSS/SASS files

// eslint-disable-next-line import/no-unresolved
require('ace-css/css/ace.css');

require('./styles/main.scss');


// Inject bundled Elm app into div#main
// eslint-disable-next-line import/no-unresolved
const Elm = require('../elm/Main');
const initElmPorts = require('./elm-ports.js')
    .default;

const app = Elm.Main.embed(document.getElementById('main'), {
    courseTitle: COURSE_TITLE,
    piazzaURL: PIAZZA_URL,
    aboutURL: ABOUT_URL,
    canvasURL: CANVAS_URL,
});
initElmPorts(app);
