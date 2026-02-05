--[[
    This is a part of "Mapblock Shepherd".
    Copyright (C) 2023-2024 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

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

local ms = mapchunk_shepherd

local mod_path = minetest.get_modpath("mapchunk_shepherd")
local sizes = dofile(mod_path.."/sizes.lua")

ms.units = {}
local units = ms.units

-- Translates node position into mapblock position.
function units.node_to_mapblock(pos)
    local mapblock_pos = vector.floor(pos) / sizes.mapblock.in_nodes
    return mapblock_pos
end

-- Translates node position into mapchunk position.
function units.node_to_mapchunk(pos)
    local mapchunk_pos = vector.floor(pos) - sizes.mapchunk_offset
    mapchunk_pos = mapchunk_pos / sizes.mapchunk.in_nodes
    return mapchunk_pos
end

-- Translates mapblock position into node position.
function units.mapblock_to_node(mapblock_pos)
    local pos = mapblock_pos * sizes.mapblock.in_nodes
    pos = vector.round(pos) -- round to avoid fp garbage
    return pos
end

-- Translates mapchunk position into node position.
function units.mapchunk_to_node(mapchunk_pos)
    local pos = mapchunk_pos * sizes.mapchunk.in_nodes
    pos = pos + sizes.mapchunk_offset
    pos = vector.round(pos) -- round to avoid fp garbage
    return pos
end

-- Translates mapchunk position into mapblock position.
function units.mapchunk_to_mapblock(mapchunk_pos)
    local pos = units.mapchunk_to_node(mapchunk_pos)
    return units.node_to_mapblock(pos)
end

-- Returns mapblock coordinates of the mapblock in mapblock units.
-- 'pos' is absolute node position.
function units.mapblock_coords(pos)
    local mapblock_pos = units.node_to_mapblock(pos)
    return vector.floor(mapblock_pos)
end

-- Returns mapchunk coordinates of the mapchunk in mapchunk units.
-- 'pos' is absolute node position.
function units.mapchunk_coords(pos)
    local mapchunk_pos = units.node_to_mapchunk(pos)
    return vector.floor(mapchunk_pos)
end

-- Returs origin point of a mapblock stated in absolute node position.
-- 'pos' is absolute node position.
function units.mapblock_origin(pos)
    local coords = units.mapblock_coords(pos)
    return units.mapchunk_to_node(coords)
end

-- Returs origin point of a mapchunk stated in absolute node position.
-- 'pos' is absolute node position.
function units.mapchunk_origin(pos)
    local coords = units.mapchunk_coords(pos)
    return units.mapchunk_to_node(coords)
end
