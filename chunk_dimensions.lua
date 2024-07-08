--[[
    This is a part of "Perfect City".
    Copyright (C) 2023 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

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

local mod_storage = minetest.get_mod_storage()

-- By default chunksize is 5
local blocks_per_chunk = tonumber(minetest.get_mapgen_setting("chunksize"))
local chunk_side = blocks_per_chunk * 16
-- this logic comes from Minetest source code, see src/mapgen/mapgen.cpp
local mapchunk_offset = -16 * math.floor(blocks_per_chunk / 2)
local old_chunksize = mod_storage:get_int("chunksize")

return {
    blocks_per_chunk = blocks_per_chunk,
    chunk_side = chunk_side,
    mapchunk_offset = mapchunk_offset,
    old_chunksize = old_chunksize
}
