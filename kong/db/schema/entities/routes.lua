local typedefs = require("kong.db.schema.typedefs")
local router = require("resty.router.router")
local deprecation = require("kong.deprecation")

local CACHED_SCHEMA = require("kong.router.atc").schema
local get_expression = require("kong.router.compat").get_expression

local function validate_expression(id, exp)
  local r = router.new(CACHED_SCHEMA)

  local res, err = r:add_matcher(0, id, exp)
  if not res then
    return nil, "Router Expression failed validation: " .. err
  end

  return true
end

local kong_router_flavor = kong and kong.configuration and kong.configuration.router_flavor

if kong_router_flavor == "expressions" then
  return {
    name         = "routes",
    primary_key  = { "id" },
    endpoint_key = "name",
    workspaceable = true,

    fields = {
      { id             = typedefs.uuid, },
      { created_at     = typedefs.auto_timestamp_s },
      { updated_at     = typedefs.auto_timestamp_s },
      { name           = typedefs.utf8_name },
      { protocols      = { type     = "set",
                           description = "An array of the protocols this Route should allow.",
                           len_min  = 1,
                           required = true,
                           elements = typedefs.protocol,
                           mutually_exclusive_subsets = {
                             { "http", "https" },
                             { "tcp", "tls", "udp" },
                             { "tls_passthrough" },
                             { "grpc", "grpcs" },
                           },
                           default = { "http", "https" }, -- TODO: different default depending on service's scheme
                         }, },
      { https_redirect_status_code = { type = "integer",
                                       description = "The status code Kong responds with when all properties of a Route match except the protocol",
                                       one_of = { 426, 301, 302, 307, 308 },
                                       default = 426, required = true,
                                     }, },
      { strip_path     = { description = "When matching a Route via one of the paths, strip the matching prefix from the upstream request URL.", type = "boolean", required = true, default = true }, },
      { preserve_host  = { description = "When matching a Route via one of the hosts domain names, use the request Host header in the upstream request headers.", type = "boolean", required = true, default = false }, },
      { request_buffering  = { description = "Whether to enable request body buffering or not. With HTTP 1.1.", type = "boolean", required = true, default = true }, },
      { response_buffering  = { description = "Whether to enable response body buffering or not.", type = "boolean", required = true, default = true }, },
      { tags             = typedefs.tags },
      { service = { description = "The Service this Route is associated to. This is where the Route proxies traffic to.", type = "foreign", reference = "services" }, },
      { expression = { description = " The router expression.", type = "string", required = true }, },
      { priority = { description = "A number used to choose which route resolves a given request when several routes match it using regexes simultaneously.", type = "integer", required = true, default = 0 }, },
    },

    entity_checks = {
      { custom_entity_check = {
        field_sources = { "expression", "id", },
        fn = function(entity)
          local ok, err = validate_expression(entity.id, entity.expression)
          if not ok then
            return nil, err
          end

          return true
        end,
      } },
    },
  }

-- router_flavor in ('traditional_compatible', 'traditional')
else
  return {
    name         = "routes",
    primary_key  = { "id" },
    endpoint_key = "name",
    workspaceable = true,
    subschema_key = "protocols",

    fields = {
      { id             = typedefs.uuid, },
      { created_at     = typedefs.auto_timestamp_s },
      { updated_at     = typedefs.auto_timestamp_s },
      { name           = typedefs.utf8_name },
      { protocols      = { type     = "set",
                           description = "An array of the protocols this Route should allow.",
                           len_min  = 1,
                           required = true,
                           elements = typedefs.protocol,
                           mutually_exclusive_subsets = {
                             { "http", "https" },
                             { "tcp", "tls", "udp" },
                             { "tls_passthrough" },
                             { "grpc", "grpcs" },
                           },
                           default = { "http", "https" }, -- TODO: different default depending on service's scheme
                         }, },
      { methods        = typedefs.methods },
      { hosts          = typedefs.hosts },
      { paths          = typedefs.router_paths },
      { headers = typedefs.headers {
        keys = typedefs.header_name {
          match_none = {
            {
              pattern = "^[Hh][Oo][Ss][Tt]$",
              err = "cannot contain 'host' header, which must be specified in the 'hosts' attribute",
            },
          },
        },
      } },
      { https_redirect_status_code = { type = "integer",
                                       description = "The status code Kong responds with when all properties of a Route match except the protocol",
                                       one_of = { 426, 301, 302, 307, 308 },
                                       default = 426, required = true,
                                     }, },
      { regex_priority = { description = "A number used to choose which route resolves a given request when several routes match it using regexes simultaneously.", type = "integer", default = 0 }, },
      { strip_path     = { description = "When matching a Route via one of the paths, strip the matching prefix from the upstream request URL.", type = "boolean", required = true, default = true }, },
      { path_handling  = { description = "Controls how the Service path, Route path and requested path are combined when sending a request to the upstream.", type = "string", default = "v0", one_of = { "v0", "v1" }, }, },
      { preserve_host  = { description = "When matching a Route via one of the hosts domain names, use the request Host header in the upstream request headers.", type = "boolean", required = true, default = false }, },
      { request_buffering  = { description = "Whether to enable request body buffering or not. With HTTP 1.1.", type = "boolean", required = true, default = true }, },
      { response_buffering  = { description = "Whether to enable response body buffering or not.", type = "boolean", required = true, default = true }, },
      { snis = { type = "set",
                 description = "A list of SNIs that match this Route when using stream routing.",
                 elements = typedefs.sni }, },
      { sources = typedefs.sources },
      { destinations = typedefs.destinations },
      { tags             = typedefs.tags },
      { service = { description = "The Service this Route is associated to. This is where the Route proxies traffic to.",
      type = "foreign", reference = "services" }, },
    },

    entity_checks = {
      { conditional = { if_field = "protocols",
                        if_match = { elements = { type = "string", not_one_of = { "grpcs", "https", "tls", "tls_passthrough" }}},
                        then_field = "snis",
                        then_match = { len_eq = 0 },
                        then_err = "'snis' can only be set when 'protocols' is 'grpcs', 'https', 'tls' or 'tls_passthrough'",
                      }},
      { custom_entity_check = {
        field_sources = { "path_handling" },
        fn = function(entity)
          if entity.path_handling == "v1" then
            if kong_router_flavor == "traditional" then
              deprecation("path_handling='v1' is deprecated and will be removed in future version, " ..
                          "please use path_handling='v0' instead", { after = "3.0", })

            elseif kong_router_flavor == "traditional_compatible" then
              deprecation("path_handling='v1' is deprecated and will not work under traditional_compatible " ..
                          "router_flavor, please use path_handling='v0' instead", { after = "3.0", })
            end
          end

          return true
        end,
      }},
      { custom_entity_check = {
        run_with_missing_fields = true,
        field_sources = { "id", "paths", },
        fn = function(entity)
          if kong_router_flavor == "traditional_compatible" and
             type(entity.paths) == "table" and #entity.paths > 0 then
            local exp = get_expression(entity)
            local ok, err = validate_expression(entity.id, exp)
            if not ok then
              return nil, err
            end
          end

          return true
        end,
      }},
    },
  }
end
