--[[
    This is a part of "Mapchunk Shepherd".
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

--[[
    This module defines size constants for mapblocks and nodes.
    
    Key concepts:
    - Node: Single position in the world
    - Mapblock: 16x16x16 nodes (fixed size in Luanti)
    
    Returns a table with size definitions used throughout the mod.
--]]

local sizes = {}

local mapblock_size = 16
local mapblock_max = mapblock_size - 1

sizes.node = {
    in_mapblocks = 1 / mapblock_size,
}

sizes.mapblock = {
    in_nodes = mapblock_size,
    pos_min = vector.zero(),
    pos_max = vector.new(1, 1, 1) * mapblock_max,
}

return sizes
