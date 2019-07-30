# example building using AWS ECR as the remote private registry
# export REMOTE_REPO=<yourawsid>.dkr.ecr.us-east-1.amazonaws.com/openresty
# docker build -t openresty .
# docker tag openresty $REMOTE_REPO:latest
# docker push $REMOTE_REPO:latest


FROM openresty/openresty:jessie

RUN apt-get update && apt-get install -y wget \
    && wget https://dl.eff.org/certbot-auto \
    && mv certbot-auto /usr/local/bin/certbot-auto \
    && chown root /usr/local/bin/certbot-auto \
    && chmod 0755 /usr/local/bin/certbot-auto

COPY entrypoint.sh /entrypoint.sh
COPY nginx /usr/local/openresty/nginx
COPY lualib /usr/local/openresty/lualib

ENTRYPOINT ["/entrypoint.sh"]
