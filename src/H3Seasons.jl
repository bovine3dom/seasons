module H3Seasons

using Arrow
using Downloads
using H3
using HDF4_jll
using JSON3
using TOML

const H3API = H3.API
const PROJECT_ROOT = dirname(@__DIR__)
const CONFIG = TOML.parsefile(joinpath(PROJECT_ROOT, "config.toml"))

include("Cells.jl")
include("LandMask.jl")
include("Colour.jl")
include("Output.jl")
include("NASA.jl")

export Cell, h3_cells, land_cells, split_h3, join_h3, h3_center_deg,
       read_cells, write_cells, land_cells_path, load_or_create_land_cells,
       channel_to_u8, download_nasa_month!, download_nasa_months!, process_nasa_month!, process_nasa_months!,
       nasa_data_dir, nasa_checkpoint_dir, nasa_output_dir, nasa_source_files

end
