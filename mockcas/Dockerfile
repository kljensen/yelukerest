# Custom docker file to make our builds a little more effocient.
# We want to ensure the node_modules and elm_stuff are cached.
FROM node:carbon
RUN echo woot
RUN mkdir -p /opt/app
ADD package.json /opt/app/package.json
ADD package-lock.json /opt/app/package-lock.json
RUN cd /opt/app && npm install