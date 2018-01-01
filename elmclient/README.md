# elmclient

This is a "single page application" that acts as a client
for our REST API. We expect it will be the primary way in
which students will interact with the class API. 

This code was forked from the [elm-webpack-starter](https://github.com/elm-community/elm-webpack-starter). Below,
is the original README from that project.

But first, some useful links from Kyle for Jacob
* [https://medium.com/@andyccs/webpack-and-docker-for-development-and-deployment-ae0e73243db4](Webpack and Docker for Development and Deployment)
* [https://medium.com/@zenitram.oiram/a-beginners-guide-to-making-a-single-page-app-in-elm-d1a89d3845fa](A Beginner’s Guide to making a Single Page app in Elm)
* [http://madole.github.io/blog/2015/08/26/setting-up-webpack-dev-middleware-in-your-express-application/](Setting Up Webpack Dev Middleware in Express) (a bit dated)

Note to self: we need to make this run differently in production---we shouldn't be using webpack-dev-server.


### About:
A simple Webpack setup for writing [Elm](http://elm-lang.org/) apps:

* Dev server with live reloading, HMR
* Support for CSS/SCSS (with Autoprefixer), image assets
* Bootstrap 3.3+ (Sass version)
* Bundling and minification for deployment
* Basic app scaffold, using `Html.beginnerProgram`
* A snippet of example code to get you started!


### Install:
Clone this repo into a new project folder, e.g. `my-elm-project`:
```
git clone https://github.com/moarwick/elm-webpack-starter my-elm-project
cd my-elm-project
```

Re-initialize the project folder as your own repo:
```
rm -rf .git         # on Windows: rmdir .git /s /q
git init
git add .
git commit -m 'first commit'
```

Install all dependencies using the handy `reinstall` script:
```
npm run reinstall
```
*This does a clean (re)install of all npm and elm packages, plus a global elm install.*


### Serve locally:
```
npm start
```
* Access app at `http://localhost:8080/`
* Get coding! The entry point file is `src/elm/Main.elm`
* Browser will refresh automatically on any file changes..


### Build & bundle for prod:
```
npm run build
```

* Files are saved into the `/dist` folder
* To check it, open `dist/index.html`


### Changelog

**Ver 0.8.6**
* Update Packages (-> Webpack 2)
* fix paths in file-loader
* clean up build script

**Ver 0.8.5**
* Fix loading path of generated js file, per [Issue 47](https://github.com/moarwick/elm-webpack-starter/issues/47)

**Ver 0.8.4**
* Fix hot reloading of components, per [Issue 44](https://github.com/moarwick/elm-webpack-starter/issues/44)

**Ver 0.8.3**
* Update packages
* Attempt to fix path issues when building for prod (temp)

**Ver 0.8.2**
* Webpack config improvements (PR by [Lesuk](https://github.com/moarwick/elm-webpack-starter/pull/39))

**Ver 0.8.0**
* Update to Elm 0.18, use `debug=true` on webpack loader (PR by [douglascorrea](https://github.com/moarwick/elm-webpack-starter/pull/33))
* Add a script for one-step installs
* Update to latest packages

**Ver 0.7.1**
* Fix favicon issues, per [Issue 30](https://github.com/moarwick/elm-webpack-starter/issues/30)

**Ver 0.7.0**
* Modify project structure, per [Issue 26](https://github.com/moarwick/elm-webpack-starter/issues/26)
* Include Bootstrap JS, per [Issue 28](https://github.com/moarwick/elm-webpack-starter/issues/28)
* More helpful install steps in README, per [Issue 29](https://github.com/moarwick/elm-webpack-starter/issues/29)
* Update to latest packages

**Ver 0.6.2**
* Use `copy-webpack-plugin` instead of `cp` to copy files (Windows compatible)

**Ver 0.6.0**
* `elm-hot-loader` is back (no Elm code changes required!)
* Switch to [bootstrap-sass](https://www.npmjs.com/package/bootstrap-sass) to demo CSS

**Ver 0.5.0**
* Update to Elm 0.17.0 (and other latest modules)
* Upgrade starter code per [upgrade-docs](https://github.com/elm-lang/elm-platform/blob/master/upgrade-docs/0.17.md)
* Remove `elm-hot-loader` (for now)

**Ver 0.4.0**
* Add [elm-hot-loader](https://github.com/fluxxu/elm-hot-loader) for HMR support (PR by [fluxxu](https://github.com/fluxxu))

**Ver 0.3.0**
* Use `html-webpack-plugin` to generate `index.html`
* Apply hash filenames for bundled JS and CSS (prevents caching)
* Image and favicon assets copied to `dist/`
