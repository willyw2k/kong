local singletons = require "kong.singletons"
local pl_tablex = require "pl.tablex"


local setmetatable = setmetatable
local ipairs = ipairs
local type = type


local EMPTY = pl_tablex.readonly {}


local mt_cache = { __mode = "k" }
local consumer_groups_cache = setmetatable({}, mt_cache)
local consumer_in_groups_cache = setmetatable({}, mt_cache)


local function load_groups_into_memory(consumer_id)
  return singletons.dao.acls:find_all {consumer_id = consumer_id}
end


--- Returns the database records with groups the consumer belongs to
-- @param conumer_id (string) the consumer for which to fetch the groups it belongs to
-- @return table with group records (empty table if none), or nil+error
local function get_consumer_groups_raw(consumer_id)
  local cache_key = singletons.dao.acls:cache_key(consumer_id)
  local raw_groups, err = singletons.cache:get(cache_key, nil,
                                               load_groups_into_memory,
                                               consumer_id)
  if err then
    return nil, err
  end

  -- use EMPTY to be able to use it as a cache key, since a new table would
  -- immediately be collected again and not allow for negative caching.
  return raw_groups or EMPTY
end


--- Returns a table with all group names a consumer belongs to.
-- The table will have an array part to iterate over, and a hash part
-- where each group name is indexed by itself. Eg.
-- {
--   [1] = "users",
--   [2] = "admins",
--   users = "users",
--   admins = "admins",
-- }
-- If there are no groups defined, it will return an empty table
-- @param consumer_id (string) the consumer for which to fetch the groups it belongs to
-- @return table with groups (empty table if none) or nil+error
local function get_consumer_groups(consumer_id)
  local raw_groups, err = get_consumer_groups_raw(consumer_id)
  if not raw_groups then
    return nil, err
  end

  local groups = consumer_groups_cache[raw_groups]
  if not groups then
    groups = {}
    consumer_groups_cache[raw_groups] = groups
    for i = 1, #raw_groups do
      local group = raw_groups[i].group
      groups[i] = group
      groups[group] = group
    end
  end
  return groups
end


--- Returns a table with all group names.
-- The table will have an array part to iterate over, and a hash part
-- where each group name is indexed by itself. Eg.
-- {
--   [1] = "users",
--   [2] = "admins",
--   users = "users",
--   admins = "admins",
-- }
-- If there are no groups defined, it will return an empty table
-- @param ctx current ngx.ctx passed as an argument
-- @return table with groups or nil
local function get_authenticated_groups(ctx)
  if type(ctx.authenticated_groups) ~= "table" then
    return nil
  end

  local groups = {}
  for i, group in ipairs(groups) do
    groups[i] = group
    groups[group] = group
  end

  return groups
end


--- Checks whether a group-list is part of a given list of groups.
-- @param groups_to_check (table) an array of group names. Note: since the
-- results will be cached by this table, always use the same table for the
-- same set of groups!
-- @param authenticated_groups (table) list of groups
-- @return (boolean) whether the authenticated groups is found from the groups.
local function in_groups(groups_to_check, authenticated_groups)
  -- 1st level cache on "groups_to_check"
  local result1 = consumer_in_groups_cache[groups_to_check]
  if result1 == nil then
    result1 = setmetatable({}, mt_cache)
    consumer_in_groups_cache[groups_to_check] = result1
  end

  -- 2nd level cache on "consumer_groups"
  local result2 = result1[authenticated_groups]
  if result2 ~= nil then
    return result2
  end

  -- not found, so validate and populate 2nd level cache
  result2 = false
  for i = 1, #groups_to_check do
    if authenticated_groups[groups_to_check[i]] then
      result2 = true
      break
    end
  end
  result1[authenticated_groups] = result2
  return result2
end


--- Checks whether a consumer is part of the gieven list of groups
-- @param groups_to_check (table) an array of group names. Note: since the
-- results will be cached by this table, always use the same table for the
-- same set of groups!
-- @param consumer_id (string) id of consumer to verify
local function consumer_id_in_groups(groups_to_check, consumer_id)
  local consumer_groups, err = get_consumer_groups(consumer_id)
  if not consumer_groups then
    return nil, err
  end
  return in_groups(groups_to_check, consumer_groups)
end


--- Gets the currently identified consumer for the request.
-- Checks both consumer and if not found the credentials.
-- @param ctx current ngx.ctx passed as an argument
-- @return consumer_id (string), or alternatively `nil` if no consumer was
-- authenticated.
local function get_current_consumer_id(ctx)
  return (ctx.authenticated_consumer or EMPTY).id or
         (ctx.authenticated_credential or EMPTY).consumer_id
end


return {
  get_authenticated_groups = get_authenticated_groups,
  get_consumer_groups = get_consumer_groups,
  in_groups = in_groups,
  consumer_in_groups = in_groups,
  consumer_id_in_groups = consumer_id_in_groups,
  get_current_consumer_id = get_current_consumer_id,
}
