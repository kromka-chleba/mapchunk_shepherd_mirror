--[[
    This is a part of "Perfect City".
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

minetest.set_gen_notify({custom=true}, nil, {"mapchunk_shepherd:labeler"})

minetest.register_on_generated(
    function(minp, maxp, blockseed)
		local gennotify = minetest.get_mapgen_object("gennotify")
		local changed = gennotify.custom["mapchunk_shepherd:labeler"] or {}
		for _, c in ipairs(changed) do
            ms.handle_labels(unpack(c))
		end
    end
)
