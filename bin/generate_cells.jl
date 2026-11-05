using H3Seasons

cells = H3Seasons.load_or_create_land_cells()
println("Ready: $(length(cells)) land H3 centres at resolution $(H3Seasons.CONFIG["resolution"]).")
