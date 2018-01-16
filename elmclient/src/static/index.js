// pull in desired CSS/SASS files

require('ace-css/css/ace.css');
// require('milligram-scss/src/milligram.scss');
require('font-awesome/css/font-awesome.css');

// require('source-code-pro');

require('./styles/main.scss');

// const $ = jQuery = require( '../../node_modules/jquery/dist/jquery.js' );
// // <--- remove if jQuery not needed
// require('../../node_modules/bootstrap-sass/assets/javascripts/bootstrap.js' );
// // <--- remove if Bootstrap's JS not needed 

// inject bundled Elm app into div#main
const Elm = require('../elm/Main');
Elm.Main.embed(document.getElementById('main'));
