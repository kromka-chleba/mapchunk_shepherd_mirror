--[[
    This is a part of "Mapchunk Shepherd".
    Copyright (C) 2024 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
--]]

-- Globals
local ms = mapchunk_shepherd

local mod_path = core.get_modpath('mapchunk_shepherd')
local sizes = dofile(mod_path.."/sizes.lua")

-- We're in mapgen env when 'core.save_gen_notify' is a function.
-- In the ordinary env 'core.save_gen_notify' is nil.
local mapgen_env = core.save_gen_notify
local mod_storage

if not mapgen_env then
    mod_storage = core.get_mod_storage()
end

-- Checks if a function with name 'function_name' was used in the mapgen
-- env, asserts if so.
local function check_mapgen_env(function_name)
    assert(not mapgen_env,
           string.format(
               "Mapchunk Shepherd: chunk_utils: "..
               "trying to call the '%s' function from the mapgen env.",
               function_name))
end

-- Returns the side length of a mapblock in nodes (always 16).
function ms.block_side()
    return sizes.mapblock.in_nodes
end

-- Internal storage key encoder for mod storage compatibility.
-- Converts blockpos coordinates to a base64-encoded string.
-- This format is used only for internal database storage.
local function storage_hash(coords)
    local str = coords.x.."_"..coords.y.."_"..coords.z
    return core.encode_base64(str)
end

-- Internal storage key decoder.
-- Converts base64-encoded storage key back to blockpos coordinates.
-- This is the inverse of storage_hash() and used only internally.
local function storage_unhash(hash)
    local decoded = core.decode_base64(hash)
    local a = decoded:split("_")
    return vector.new(a[1], a[2], a[3])
end

-- Public API: Returns mapblock hash using Luanti's standard hash.
-- pos: position in nodes
function ms.mapblock_hash(pos)
    local coords = ms.units.mapblock_coords(pos)
    return core.hash_node_position(coords)
end

-- Returns the node position (of the origin) for a mapblock given by 'blockpos'.
-- blockpos: table with x, y, z coordinates in mapblock units
function ms.mapblock_pos_to_node(blockpos)
    return ms.units.mapblock_to_node(blockpos)
end

-- Returns origin and terminus positions of a mapblock given by blockpos.
function ms.mapblock_min_max(blockpos)
    local pos_min = ms.mapblock_pos_to_node(blockpos)
    local pos_max = pos_min + sizes.mapblock.pos_max
    return pos_min, pos_max
end

-- Saves the current game time as the last modification time for a mapblock.
-- blockpos: Mapblock position (table with x, y, z)
function ms.save_time(blockpos)
    check_mapgen_env("save_time")
    local time = core.get_gametime()
    local storage_key = storage_hash(blockpos).."_time"
    mod_storage:set_int(storage_key, time)
end

-- Resets the last modification time for a mapblock to 0.
-- blockpos: Mapblock position (table with x, y, z)
function ms.reset_time(blockpos)
    check_mapgen_env("reset_time")
    local storage_key = storage_hash(blockpos).."_time"
    mod_storage:set_int(storage_key, 0)
end

-- Returns the time in game seconds since a mapblock was last modified.
-- blockpos: Mapblock position (table with x, y, z)
function ms.time_since_last_change(blockpos)
    check_mapgen_env("time_since_last_change")
    local current_time = core.get_gametime()
    local storage_key = storage_hash(blockpos).."_time"
    return current_time - mod_storage:get_int(storage_key)
end

-- Increments the tracked block counter in mod storage.
function ms.bump_tracked_counter()
    check_mapgen_env("bump_tracked_counter")
    local counter = mod_storage:get_int("counter")
    counter = counter + 1
    mod_storage:set_int("counter", counter)
end

-- Decrements the tracked block counter in mod storage (minimum 0).
function ms.debump_tracked_counter()
    check_mapgen_env("debump_tracked_counter")
    local counter = mod_storage:get_int("counter")
    counter = counter - 1
    if counter < 0 then
        counter = 0
    end
    mod_storage:set_int("counter", counter)
end

-- Returns the current count of tracked blocks.
function ms.tracked_block_counter()
    check_mapgen_env("tracked_block_counter")
    return mod_storage:get_int("counter")
end

-- Adds and removes labels for the mapblock at a given position.
-- pos: Node position vector to identify the mapblock.
-- labels_to_add: Table of tag strings to add.
-- labels_to_remove: Table of tag strings to remove.
function ms.labels_to_position(pos, labels_to_add, labels_to_remove)
    check_mapgen_env("labels_to_position")
    local blockpos = ms.units.mapblock_coords(pos)
    local ls = ms.label_store.new(blockpos)
    ls:add_labels(labels_to_add)
    ls:remove_labels(labels_to_remove)
    ls:save_to_disk()
end

-- Internal: Get storage key for a block
function ms.get_storage_key(blockpos)
    return "block_"..storage_hash(blockpos)
end
