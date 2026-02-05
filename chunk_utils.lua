--[[
    This is a part of "Mapblock Shepherd".
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
               "Mapblock Shepherd: chunk_utils: "..
               "trying to call the '%s' function from the mapgen env.",
               function_name))
end

function ms.chunk_side()
    return sizes.mapchunk.in_nodes
end

-- Encodes node position in a format that works with mod storage.
-- Previously I used a bare bones hash returned by
-- `core.hash_node_position` which was buggy because mod storage did
-- an implicit `tostring()` which scrambled the x coordinate.
function ms.hash(coords)
    local str = coords.x.."_"..coords.y.."_"..coords.z
    return core.encode_base64(str)
end

-- Decodes hash produced by `ms.hash`.
-- Returns a luanti vector (position).
function ms.unhash(hash)
    local decoded = core.decode_base64(hash)
    local a = decoded:split("_")
    return vector.new(a[1], a[2], a[3])
end

-- Returns mapblock hash. 'pos' - position in nodes
function ms.mapblock_hash(pos)
    local coords = ms.units.mapblock_coords(pos)
    return ms.hash(coords)
end

-- Returns mapchunk hash. 'pos' - position in nodes
function ms.mapchunk_hash(pos)
    local coords = ms.units.mapchunk_coords(pos)
    return ms.hash(coords)
end

-- Returns node position (of the origin) for a mapblock given by 'hash'.
function ms.mapblock_hash_to_pos(hash)
    local coords = ms.unhash(hash)
    return ms.units.mapblock_to_node(coords)
end

-- Returns node position (of the origin) for a mapchunk given by 'hash'.
function ms.mapchunk_hash_to_pos(hash)
    local coords = ms.unhash(hash)
    return ms.units.mapchunk_to_node(coords)
end

-- Returns origin and terminus positions of a mapblock given by
-- `hash`. Hash is expected to be a block position (coordinate)
-- encoded with `ms.hash`.
function ms.mapblock_min_max(hash)
    local pos_min = ms.mapblock_hash_to_pos(hash)
    local pos_max = pos_min + sizes.mapblock.pos_max
    return pos_min, pos_max
end

-- Returns origin and terminus positions of a mapchunk given by
-- `hash`. Hash is expected to be a mapchunk position (coordinate)
-- encoded with `ms.hash`.
function ms.mapchunk_min_max(hash)
    local pos_min = ms.mapchunk_hash_to_pos(hash)
    local pos_max = pos_min + sizes.mapchunk.pos_max
    return pos_min, pos_max
end

local function get_inner_corners(mapchunk_origin)
    local corners = {}
    if sizes.mapchunk.in_mapblocks <= 1 then
        -- No corners, just one mapblock
        local hash = core.hash_node_position(mapchunk_origin)
        return {[hash] = mapchunk_origin}
    end
    local ori_coords = ms.units.mapblock_coords(mapchunk_origin)
    for x = 0, 1 do
        for y = 0, 1 do
            for z = 0, 1 do
                local corner = ori_coords +
                    vector.new(x, y, z) * (sizes.mapchunk.in_mapblocks - 1)
                local v = vector.new(x == 0 and 1 or -1,
                                     y == 0 and 1 or -1,
                                     z == 0 and 1 or -1)
                local inner_corner = ms.units.mapblock_to_node(corner + v)
                local hash = core.hash_node_position(inner_corner)
                corners[hash] = inner_corner
            end
        end
    end
    return corners
end

function ms.loaded_or_active(mapchunk_origin)
    check_mapgen_env("loaded_or_active")
    local corners = get_inner_corners(mapchunk_origin)
    for _, pos in pairs(corners) do
        if core.compare_block_status(pos, "loaded") or
            core.compare_block_status(pos, "active") then
            return true
        end
    end
    return false
end

function ms.neighboring_mapchunks(hash)
    check_mapgen_env("neighboring_mapchunks")
    local pos = ms.mapchunk_hash_to_pos(hash)
    local hashes = {}
    local diameter = tonumber(core.settings:get("viewing_range")) * 2
    local nr = math.ceil(diameter / sizes.mapchunk.in_nodes)
    for z = -nr, nr do
        for y = -nr, nr do
            for x = -nr, nr do
                local v = vector.new(x, y, z) * sizes.mapchunk.in_nodes
                local mapchunk_pos = pos + v
                table.insert(hashes, ms.mapchunk_hash(mapchunk_pos))
            end
        end
    end
    return hashes
end

function ms.save_time(hash)
    check_mapgen_env("save_time")
    local time = core.get_gametime()
    mod_storage:set_int(hash.."_time", time)
end

function ms.reset_time(hash)
    check_mapgen_env("reset_time")
    mod_storage:set_int(hash"_time", 0)
end

function ms.time_since_last_change(hash)
    check_mapgen_env("time_since_last_change")
    local current_time = core.get_gametime()
    return current_time - mod_storage:get_int(hash.."_time")
end

local function bump_counter()
    check_mapgen_env("bump_counter")
    local counter = mod_storage:get_int("counter")
    counter = counter + 1
    mod_storage:set_int("counter", counter)
end

local function debump_counter()
    check_mapgen_env("debump_counter")
    local counter = mod_storage:get_int("counter")
    counter = counter - 1
    if counter < 0 then
        counter = 0
    end
    mod_storage:set_int("counter", counter)
end

function ms.tracked_chunk_counter()
    check_mapgen_env("tracked_chunk_counter")
    return mod_storage:get_int("counter")
end

function ms.labels_to_position(pos, labels_to_add, labels_to_remove)
    check_mapgen_env("labels_to_position")
    local hash = ms.mapchunk_hash(pos)
    local ls = ms.label_store.new(hash)
    ls:add_labels(labels_to_add)
    ls:remove_labels(labels_to_remove)
    ls:save_to_disk()
end
