-- This is a simple web application firewall that
-- uses honeypot URL patterns in order to identify
-- malicious IP addresses and block them. In this
-- script we're just checking to see if a remote
-- IP is in the list of banned IPs.
-- To use this WAF, you'd need two lines in your
-- nginx.conf:
--
-- In the http section:
-- lua_shared_dict banned_ips 2m;
--
-- and in the server or location section
-- access_by_lua_file '../lualib/user_code/waf.lua';
local remote_addr = ngx.var.remote_addr
local banned_ips = ngx.shared.banned_ips

local found_ip, flags = banned_ips:get(remote_addr)
if found_ip ~= nil then
  ngx.exit(ngx.HTTP_CLOSE)
end