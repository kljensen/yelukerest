# Custom docker file to make our builds a little more effocient.
# We want to ensure the node_modules and elm_stuff are cached.
FROM node:carbon

RUN mkdir -p /opt/app
ADD package.json /opt/app/package.json
ADD package-lock.json /opt/app/package-lock.json
ADD elm-package.json /opt/app/elm-package.json
RUN cd /opt/app && npm run reinstall