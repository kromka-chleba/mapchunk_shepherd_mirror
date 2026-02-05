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

local sizes = {}

-- in mapblocks
local blocks_per_chunk = tonumber(core.get_mapgen_setting("chunksize"))
-- in nodes
local mapblock_size = 16
-- in nodes
local mapchunk_size = blocks_per_chunk * mapblock_size
-- origin of the mapchunk grid expressed as absolute position stated in nodes
local mapchunk_offset = vector.new(1, 1, 1) *
    -16 * math.floor(blocks_per_chunk / 2)

-- Map divisions

sizes.mapchunk_offset = mapchunk_offset

sizes.node = {
    in_mapblocks = 1 / mapblock_size,
    in_mapchunks = 1 / mapchunk_size,
}

local mapblock_max = mapblock_size - 1

sizes.mapblock = {
    in_nodes = mapblock_size,
    in_mapchunks = 1 / blocks_per_chunk,
    pos_min = vector.zero(),
    pos_max = vector.new(1, 1, 1) * mapblock_max,
}

local mapchunk_max = mapchunk_size - 1

sizes.mapchunk = {
    in_nodes = mapchunk_size,
    in_mapblocks = blocks_per_chunk,
    pos_min = vector.zero(),
    pos_max = vector.new(1, 1, 1) * mapchunk_max,
}

return sizes
