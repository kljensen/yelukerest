const path = require('path');
const webpack = require('webpack');
const merge = require('webpack-merge');
const HtmlWebpackPlugin = require('html-webpack-plugin');
const autoprefixer = require('autoprefixer');
const ExtractTextPlugin = require('extract-text-webpack-plugin');
const CopyWebpackPlugin = require('copy-webpack-plugin');
const CompressionPlugin = require('compression-webpack-plugin');

const prod = 'production';
const dev = 'development';

// determine build env
const TARGET_ENV = process.env.DEVELOPMENT ? dev : prod;
const isDev = TARGET_ENV === dev;
const isProd = TARGET_ENV === prod;

// entry and output path/filename variables
const entryPath = path.join(__dirname, 'src/static/index.js');
const outputPath = path.join(__dirname, 'dist');
const outputFilename = isProd ? '[name]-[hash].js' : '[name].js';

// eslint-disable-next-line no-console
console.log(`WEBPACK GO! Building for ${TARGET_ENV}`);

// common webpack config (valid for dev and prod)
const commonConfig = {
    output: {
        path: outputPath,
        filename: `static/js/${outputFilename}`,
    },
    resolve: {
        extensions: ['.js', '.elm'],
        modules: ['node_modules'],
    },
    module: {
        noParse: /\.elm$/,
        rules: [{
            test: /\.(eot|ttf|woff|woff2|svg)$/,
            use: 'file-loader?publicPath=../../&name=static/css/[hash].[ext]',
        }],
    },
    plugins: [
        new webpack.LoaderOptionsPlugin({
            options: {
                postcss: [autoprefixer()],
            },
        }),
        new HtmlWebpackPlugin({
            template: 'src/static/index.html',
            inject: 'body',
            filename: 'index.html',
        }),
        new webpack.DefinePlugin({
            // Todo: get these via a call to the database instead
            // of through the environment. (?)
            COURSE_TITLE: JSON.stringify(process.env.COURSE_TITLE),
            PIAZZA_URL: JSON.stringify(process.env.PIAZZA_URL),
            ABOUT_URL: JSON.stringify(process.env.ABOUT_URL),
        }),
    ],
};

// additional webpack settings for local env (when invoked by 'npm start')
if (isDev === true) {
    module.exports = merge(commonConfig, {
        entry: entryPath,
        // Watch files in dev mode and rebuild on change
        watch: true,
        watchOptions: {
            aggregateTimeout: 300,
            poll: 1000,
            ignored: /(node_modules|elm-stuff)/,
        },
        module: {
            rules: [{
                test: /\.elm$/,
                exclude: [/elm-stuff/, /node_modules/],
                use: [{
                    loader: 'elm-webpack-loader',
                    options: {
                        verbose: true,
                        warn: true,
                        debug: true,
                    },
                }],
            }, {
                test: /\.css$/,
                use: ['style-loader', 'css-loader', 'postcss-loader'],
            }, {
                test: /\.sc?ss$/,
                use: ['style-loader', 'css-loader', 'postcss-loader', 'sass-loader'],
            }],
        },
    });
}

// additional webpack settings for prod env (when invoked via 'npm run build')
if (isProd === true) {
    module.exports = merge(commonConfig, {
        entry: entryPath,
        module: {
            rules: [{
                test: /\.elm$/,
                exclude: [/elm-stuff/, /node_modules/],
                use: 'elm-webpack-loader',
            }, {
                test: /\.css$/,
                use: ExtractTextPlugin.extract({
                    fallback: 'style-loader',
                    use: ['css-loader', 'postcss-loader'],
                }),
            }, {
                test: /\.sc?ss$/,
                use: ExtractTextPlugin.extract({
                    fallback: 'style-loader',
                    use: ['css-loader', 'postcss-loader', 'sass-loader'],
                }),
            }],
        },
        plugins: [
            new ExtractTextPlugin({
                filename: 'static/css/[name]-[hash].css',
                allChunks: true,
            }),
            new CopyWebpackPlugin([{
                from: 'src/static/img/',
                to: 'static/img/',
            }, {
                from: 'src/favicon.ico',
            }]),

            // extract CSS into a separate file
            // minify & mangle JS/CSS
            new webpack.optimize.UglifyJsPlugin({
                minimize: true,
                compressor: {
                    warnings: false,
                },
                // mangle:  true
            }),
            new webpack.optimize.AggressiveMergingPlugin(),
            // Make a .gz copy of each asset
            new CompressionPlugin({
                test: /\.js$|\.css$|\.html$/,
            }),
        ],
    });
}
