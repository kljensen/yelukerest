local http = require('resty.http')
local session_store = require "resty.session"
-- session_store.cookie.samesite = "Strict"

local conf = {
   cas_uri = "https://localhost/cas";
}
local cas_uri = conf.cas_uri


-- In development mode, we skip ssl verification because
-- it is likely we're using self-signed certificates.
local ssl_verify = true
if ngx.var.development ~= nil then
   ssl_verify = false
end

local function _uri_without_ticket()
   return ngx.var.scheme .. "://" .. ngx.var.host ..  ngx.re.sub(ngx.var.request_uri, "[?&]ticket=.*", "")
end

local function _cas_login()
   return cas_uri .. "/login?" .. ngx.encode_args({ service = _uri_without_ticket() })
end

local function first_access()
   ngx.redirect(_cas_login(), ngx.HTTP_MOVED_TEMPORARILY)
end

-- Contact the CAS server to validate a ticket.
-- returns `nil` in case of an invalid ticket.
--
local function _validate(ticket)
   -- send a request to CAS to validate the ticket
   local httpc = http.new()
   local res, err = httpc:request_uri(cas_uri .. "/serviceValidate", { query = { ticket = ticket, service = _uri_without_ticket() }, ssl_verify = ssl_verify })
  
   if res and res.status == ngx.HTTP_OK and res.body ~= nil then
      if string.find(res.body, "<cas:authenticationSuccess>") then
         local m = ngx.re.match(res.body, "<cas:user>(.*?)</cas:user>");
         if m then
            return m[1]
         end
      else
         ngx.log(ngx.INFO, "CAS serviceValidate failed: " .. res.body)
      end
   else
      ngx.log(ngx.ERR, err)
   end
   return nil
end


-- Grab the `ticket` query parameter from the request
-- URL and validate this ticket with the CAS server.
-- If the ticket is valid, reload the current page without
-- the `ticket` URL parameter.
--
local function validate_with_CAS(ticket)
   local netid = _validate(ticket)
   if netid then
      -- remove ticket from url
      local session = session_store.start()
      session.data.netid = netid
      session:save()
      -- TODO: handle case of save failure?
      ngx.redirect(_uri_without_ticket(), ngx.HTTP_MOVED_TEMPORARILY)
   else
      first_access()
   end
end

local function forceAuthentication()
   local session = session_store.open()
   
   -- VALID SESSION
   if session.data.netid ~= nil then
      -- Let them proceed and set the ngx.ctx.netid variable so
      -- that it can be accessed in other routes without reading
      -- cookies or the session store again.
      -- See https://github.com/openresty/lua-nginx-module#ngxctx
      ngx.ctx.netid = session.data.netid
      return
   end

   -- INVALID SESSION OR NO SESSION
   -- Delete any cookies they sent
   session:destroy()
   local ticket = ngx.var.arg_ticket
   if ticket ~= nil then
      -- They are trying to validate a ticket, e.g.
      -- they were redirected back here from 
      validate_with_CAS(ticket)
   else
      first_access()
   end
end

local function logout()
   local session = session_store.open()
   session:destroy()
end

-- Redirect the user either to the URL specifiied in the request's
-- ?next= parameter or to the homepage.
local function redirect_to_next()
   local next = ngx.var.arg_next or "/"
   ngx.redirect(next, ngx.HTTP_MOVED_TEMPORARILY)
end

return {
   forceAuthentication = forceAuthentication;   
   logout = logout;
   redirect_to_next=redirect_to_next;
}