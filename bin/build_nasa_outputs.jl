using H3Seasons

months = isempty(ARGS) ? H3Seasons.CONFIG["months"] : parse.(Int, ARGS)
cells = H3Seasons.load_or_create_land_cells()
H3Seasons.process_nasa_months!(months, cells)
println("Monthly Arrow files are in $(H3Seasons.nasa_output_dir()).")
