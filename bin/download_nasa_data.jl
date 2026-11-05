using H3Seasons

months = isempty(ARGS) ? H3Seasons.CONFIG["months"] : parse.(Int, ARGS)
H3Seasons.download_nasa_months!(months)
println("NASA HDF files are ready in $(H3Seasons.nasa_data_dir()).")
