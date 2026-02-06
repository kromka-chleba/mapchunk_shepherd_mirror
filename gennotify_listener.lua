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

-- Register for custom gennotify objects from mapgen environment.
core.set_gen_notify({custom=true}, nil, {"mapchunk_shepherd:labeler"})

-- Callback that processes label changes sent from mapgen environment.
-- Receives staged labels via gennotify and saves them to mod storage.
core.register_on_generated(
    function(minp, maxp, blockseed)
        local label_stores = {}
		local gennotify = core.get_mapgen_object("gennotify")
		local changed = gennotify.custom["mapchunk_shepherd:labeler"] or {}
		for _, c in ipairs(changed) do
            local block_hash, blockpos, staged_labels = unpack(c)
            local storage_key = ms.get_storage_key(blockpos)
            local ls = label_stores[storage_key] or ms.label_store.new(block_hash, blockpos)
            label_stores[storage_key] = ls
            ls.staged_labels = staged_labels
            ls:set_labels()
		end
        for _, ls in pairs(label_stores) do
            ls:save_to_disk()
        end
    end
)
