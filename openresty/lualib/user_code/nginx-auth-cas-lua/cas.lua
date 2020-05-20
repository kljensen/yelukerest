local http = require('resty.http')
local session_store = require "resty.session"
local authapp = require "authapp"
local cas_uri = os.getenv("AUTHAPP_CAS_URI")

local function starts_with(str, start)
   return str:sub(1, #start) == start
end

local function starts_with_http(uri)
   return type(uri) == "string" and starts_with(uri, "http")
end

assert(starts_with_http(cas_uri), "Environment variable AUTHAPP_CAS_URI is not set or invalid")

local conf = {
   cas_uri = cas_uri;
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

-- Check if user is registered
local function user_is_registered(netid)
   local jwt, err, status_code = authapp.fetch_user_jwt(netid)
   if jwt ~= nil and err == nil then
      return true
   end
   return false
end

-- Grab the `ticket` query parameter from the request
-- URL and validate this ticket with the CAS server.
-- If the ticket is valid, reload the current page without
-- the `ticket` URL parameter.
--
local function validate_with_CAS(ticket)

   -- Did the ticket validate?
   local netid = _validate(ticket)
   if netid == nil or netid == "" then
      ngx.log(ngx.WARN, "ticket validation failed")
      return ngx.exit(ngx.HTTP_FORBIDDEN)
   end

   -- Is the user in the database? Contact our API.
   if not user_is_registered(netid) then
      ngx.log(ngx.WARN, "user ", netid, " is not registererd")
      return ngx.exit(ngx.HTTP_FORBIDDEN)
   end

   -- Save the session info
   -- TODO: handle case of save failure?
   local session = session_store.start()
   session.data.netid = netid
   session:save()

   -- remove ticket from url
   local new_url = _uri_without_ticket()
   return ngx.redirect(new_url, ngx.HTTP_MOVED_TEMPORARILY)
end

local function get_netid_from_session(session)
   -- VALID SESSION
   if session.data.netid ~= nil then
      -- Let them proceed and set the ngx.ctx.netid variable so
      -- that it can be accessed in other routes without reading
      -- cookies or the session store again.
      -- See https://github.com/openresty/lua-nginx-module#ngxctx
      ngx.ctx.netid = session.data.netid
      return session.data.netid
   end
   return nil
end


local function session_and_netid()
   local session = session_store.open()
   local netid = get_netid_from_session(session)
   return session, netid
end


-- Checks to see if there is a cookie and, if there is,
-- destroys the session associated with that cookie, setting
-- a new empty cookie in the client.
local function destroy_invalid_session(session)
   -- INVALID SESSION OR NO SESSION
   local cookie = session:get_cookie()
   local had_cookie = cookie ~= nil
   if had_cookie then
      -- Delete any cookies they sent
      session:destroy()
   end
   return had_cookie
end

-- Handle auth, everything else is a wrapper
-- around this.
local function authentication(force)
   local session, netid = session_and_netid()

   -- Valid session. Let them pass.
   if netid ~= nil then
      return
   end

   -- Invalid session
   local had_cookie = destroy_invalid_session(session)

   -- we're done. This person is either unauthorized
   -- (they sent no session info) or forbidden (what
   -- they sent was invalid.)
   if not force then
      local status_code = ngx.HTTP_UNAUTHORIZED
      if had_cookie then
         status_code = ngx.HTTP_FORBIDDEN
      end
      ngx.exit(status_code)
   end

   -- See if they are trying to validate a ticket,
   -- e.g. they just returned from the CAS server.
   local ticket = ngx.var.arg_ticket
   if ticket ~= nil then
      -- They are trying to validate a ticket, e.g.
      -- they were redirected back here from 
      validate_with_CAS(ticket)
   else
      first_access()
   end
end

-- This function should be used like
-- ```
-- access_by_lua_block {
--   require('cas').require_authentication()
-- }
-- The user will be permitted if they have a
-- valid session. Otherwise they will get a 401
-- unauthorized.
--       
local function require_authentication()
   return authentication(false)
end

-- This function should be used like
-- ```
-- access_by_lua_block {
--   require('cas').force_authentication()
-- }
-- The user will be permitted if they have a
-- valid session. Otherwise they will  be redirected
-- to the CAS server and back with a ticket.
-- Valid tickets will get a session
--
local function force_authentication()
   return authentication(true)
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
   require_authentication = require_authentication;
   force_authentication = force_authentication;   
   logout = logout;
   redirect_to_next=redirect_to_next;
}