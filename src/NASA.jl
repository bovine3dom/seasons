const NASA_SOURCE_FILES = [
    "MCD43C4.A2025001.061.2025011043119.hdf",
    "MCD43C4.A2025032.061.2025044044345.hdf",
    "MCD43C4.A2025060.061.2025069060315.hdf",
    "MCD43C4.A2025091.061.2025101005849.hdf",
    "MCD43C4.A2025121.061.2025130183852.hdf",
    "MCD43C4.A2025152.061.2025163103529.hdf",
    "MCD43C4.A2025182.061.2025191065426.hdf",
    "MCD43C4.A2025213.061.2025224002219.hdf",
    "MCD43C4.A2025244.061.2025253204341.hdf",
    "MCD43C4.A2025274.061.2025283072404.hdf",
    "MCD43C4.A2025305.061.2025317145524.hdf",
    "MCD43C4.A2025335.061.2025348070002.hdf",
]
const NASA_BANDS = ("Nadir_Reflectance_Band1", "Nadir_Reflectance_Band4", "Nadir_Reflectance_Band3")
const NASA_ROWS, NASA_COLS = 3600, 7200
const NASA_FILL = Int16(32767)

nasa_source_files() = copy(NASA_SOURCE_FILES)
nasa_data_dir() = joinpath(PROJECT_ROOT, "cache", "nasa_mcd43c4_$(CONFIG["year"])")
nasa_checkpoint_dir() = joinpath(nasa_data_dir(), "global_land_r$(CONFIG["resolution"])")
nasa_output_dir() = joinpath(PROJECT_ROOT, "out", "planet_mcd43c4_$(CONFIG["year"])")

function nasa_month_path(month::Integer; data_dir::AbstractString=nasa_data_dir())
    month in eachindex(NASA_SOURCE_FILES) || throw(ArgumentError("month must be between 1 and 12"))
    joinpath(data_dir, NASA_SOURCE_FILES[month])
end

function nasa_token()
    token = strip(get(ENV, "EARTH_DATA_BEARER", ""))
    !isempty(token) && return token
    env_path = joinpath(PROJECT_ROOT, ".env")
    if isfile(env_path)
        for line in eachline(env_path)
            pair = split(strip(line), '='; limit=2)
            length(pair) == 2 || continue
            key = strip(replace(pair[1], r"^export\s+" => ""))
            key == "EARTH_DATA_BEARER" || continue
            token = strip(pair[2])
            if length(token) >= 2 && first(token) == last(token) && first(token) in ('\'', '"')
                token = token[2:end-1]
            end
            isempty(token) || return token
        end
    end
    error("Set EARTH_DATA_BEARER in the environment or project .env file")
end

function is_hdf4_file(path::AbstractString)
    isfile(path) && filesize(path) >= 4 || return false
    open(path, "r") do io
        read(io, 4) == UInt8[0x0e, 0x03, 0x13, 0x01]
    end
end

function download_nasa_month!(month::Integer; data_dir::AbstractString=nasa_data_dir(), token=nothing)
    path = nasa_month_path(month; data_dir)
    is_hdf4_file(path) && (@info "Using cached NASA HDF" month path; return path)
    token === nothing && (token = nasa_token())
    mkpath(data_dir)
    url = "$(CONFIG["nasa"]["archive_url"])/$(CONFIG["year"])/$(NASA_SOURCE_FILES[month])"
    temporary = path * ".download"
    for attempt in 1:5
        response = try
            open(temporary, "w") do output
                Downloads.request(url; headers=["Authorization" => "Bearer $token"], output, timeout=600)
            end
        catch
            isfile(temporary) && rm(temporary; force=true)
            rethrow()
        end
        if response.status == 200 && is_hdf4_file(temporary)
            mv(temporary, path; force=true)
            @info "Downloaded NASA MCD43C4 file" month path bytes=filesize(path)
            return path
        end
        isfile(temporary) && rm(temporary; force=true)
        if response.status in (401, 403) || response.status == 200
            error("NASA rejected the download or returned a sign-in page. Sign in to Earthdata Login, open $(CONFIG["nasa"]["product_url"]), and accept any required licence terms.")
        end
        response.status in (429, 500, 502, 503, 504) && attempt < 5 ||
            error("NASA LAADS returned HTTP $(response.status) for $url")
        @warn "NASA download failed; retrying" month attempt status=response.status
        sleep(2^(attempt - 1))
    end
    error("NASA download failed after five attempts for month $month")
end

function download_nasa_months!(months=CONFIG["months"]; data_dir::AbstractString=nasa_data_dir())
    foreach(month -> download_nasa_month!(month; data_dir), months)
    nothing
end

function read_full_band(path::AbstractString, name::AbstractString)
    fid = ccall((:SDstart, HDF4_jll.libmfhdf), Int32, (Cstring, Int32), path, 1)
    fid >= 0 || error("Could not open HDF4 file $path")
    sds = Cint(-1)
    try
        index = ccall((:SDnametoindex, HDF4_jll.libmfhdf), Int32, (Int32, Cstring), fid, name)
        index >= 0 || error("Band $name is missing from $path")
        sds = ccall((:SDselect, HDF4_jll.libmfhdf), Int32, (Int32, Int32), fid, index)
        sds >= 0 || error("Could not select band $name in $path")
        data = Vector{Int16}(undef, NASA_ROWS * NASA_COLS)
        start, edges = Int32[0, 0], Int32[NASA_ROWS, NASA_COLS]
        status = GC.@preserve data start edges ccall((:SDreaddata, HDF4_jll.libmfhdf), Cint,
            (Int32, Ptr{Int32}, Ptr{Int32}, Ptr{Int32}, Ptr{Cvoid}),
            sds, pointer(start), C_NULL, pointer(edges), pointer(data))
        status == 0 || error("Could not read band $name from $path")
        data
    finally
        sds >= 0 && ccall((:SDendaccess, HDF4_jll.libmfhdf), Cint, (Int32,), sds)
        ccall((:SDend, HDF4_jll.libmfhdf), Cint, (Int32,), fid)
    end
end

valid_rgb(r, g, b, i) = 0 <= r[i] < NASA_FILL && 0 <= g[i] < NASA_FILL && 0 <= b[i] < NASA_FILL
unit_vector(lat, lon) = (cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))

function candidate_bounds(h::UInt64, center_lat, center_lon)
    boundary = H3API.cellToBoundary(h)
    latitudes = getproperty.(boundary, :lat)
    pixel_size = deg2rad(0.05)
    row_start = floor(Int, (pi / 2 - maximum(latitudes)) / pixel_size) - 1
    row_stop = floor(Int, (pi / 2 - minimum(latitudes)) / pixel_size) + 1
    row_range = clamp(row_start, 0, NASA_ROWS - 1):clamp(row_stop, 0, NASA_ROWS - 1)
    longitude_deltas = map(boundary) do point
        mod(point.lng - center_lon + pi, 2pi) - pi
    end
    if maximum(longitude_deltas) - minimum(longitude_deltas) >= pi
        col_range = 0:(NASA_COLS - 1)
    else
        col_start = floor(Int, (center_lon + minimum(longitude_deltas) + pi) / pixel_size) - 1
        col_stop = floor(Int, (center_lon + maximum(longitude_deltas) + pi) / pixel_size) + 1
        col_range = col_start:col_stop
    end
    row_range, col_range
end

function nearest_valid_pixel!(i, cells, rows, cols, red, green, blue, fallback, offset_row, offset_col,
                              raster_red, raster_green, raster_blue, pixel_sin_lat, pixel_cos_lat,
                              pixel_sin_lon, pixel_cos_lon)
    h = cells[i].h3
    center = H3API.cellToLatLng(h)
    target = unit_vector(center.lat, center.lng)
    neighbors = [unit_vector(point.lat, point.lng) for neighbor in H3API.gridDisk(h, 1) if neighbor != h
                 for point in (H3API.cellToLatLng(neighbor),)]
    row_range, raw_cols = candidate_bounds(h, center.lat, center.lng)
    cols_to_check = length(raw_cols) >= NASA_COLS ? (0:(NASA_COLS - 1)) : unique!(mod.(collect(raw_cols), NASA_COLS))
    best_dot, best_row, best_col = -Inf, -1, -1
    for row in row_range, col in cols_to_check
        pixel = row * NASA_COLS + col + 1
        (0 <= raster_red[pixel] < NASA_FILL && 0 <= raster_green[pixel] < NASA_FILL &&
         0 <= raster_blue[pixel] < NASA_FILL) || continue
        px = pixel_cos_lat[row + 1] * pixel_cos_lon[col + 1]
        py = pixel_cos_lat[row + 1] * pixel_sin_lon[col + 1]
        pz = pixel_sin_lat[row + 1]
        target_dot = target[1] * px + target[2] * py + target[3] * pz
        all(neighbor -> target_dot > neighbor[1] * px + neighbor[2] * py + neighbor[3] * pz + 1e-14,
            neighbors) || continue
        if target_dot > best_dot
            best_dot, best_row, best_col = target_dot, row, col
        end
    end
    best_row < 0 && return false
    pixel = best_row * NASA_COLS + best_col + 1
    red[i], green[i], blue[i] = raster_red[pixel], raster_green[pixel], raster_blue[pixel]
    fallback[i] = true
    offset_row[i] = Int16(best_row - rows[i])
    offset_col[i] = Int16(mod(best_col - cols[i] + NASA_COLS ÷ 2, NASA_COLS) - NASA_COLS ÷ 2)
    true
end

function checkpoint_path(month::Integer; checkpoint_dir::AbstractString=nasa_checkpoint_dir())
    joinpath(checkpoint_dir, "month_$(lpad(month, 2, '0'))_raw.arrow")
end

function load_month_checkpoint(path, cells)
    table = Arrow.Table(path)
    collect(table.h3_hi) == UInt32[cell.h3_hi for cell in cells] || error("H3 IDs differ in checkpoint $path")
    collect(table.h3_lo) == UInt32[cell.h3_lo for cell in cells] || error("H3 IDs differ in checkpoint $path")
    red, green, blue = Int16.(collect(table.r_raw)), Int16.(collect(table.g_raw)), Int16.(collect(table.b_raw))
    fallback = BitVector(table.fallback .== 1)
    old_fallbacks = findall(fallback)
    red[old_fallbacks] .= NASA_FILL
    green[old_fallbacks] .= NASA_FILL
    blue[old_fallbacks] .= NASA_FILL
    (; red, green, blue)
end

function sample_centres(cells, rows, cols, raster_red, raster_green, raster_blue)
    pixel_ids = rows .* NASA_COLS .+ cols .+ 1
    (; red=raster_red[pixel_ids], green=raster_green[pixel_ids], blue=raster_blue[pixel_ids])
end

function render_nasa_month(month, cells, raw; output_dir::AbstractString=nasa_output_dir())
    keep = findall(i -> valid_rgb(raw.red, raw.green, raw.blue, i), eachindex(cells))
    output_path = joinpath(output_dir, "planet_mcd43c4_$(CONFIG["year"])_month_$(lpad(month, 2, '0')).arrow")
    channel(values) = UInt8[channel_to_u8(value) for value in values]
    write_arrow_atomic(output_path, (
        index_lower=UInt32[cells[i].h3_lo for i in keep],
        index_upper=UInt32[cells[i].h3_hi for i in keep],
        r=channel(raw.red[keep]), g=channel(raw.green[keep]), b=channel(raw.blue[keep]),
        a=fill(UInt8(255), length(keep)),
        fallback=UInt8.(raw.fallback[keep]),
        pixel_offset_row=raw.offset_row[keep], pixel_offset_col=raw.offset_col[keep],
    ))
    @info "Wrote NASA monthly H3 data" month output_path rendered=length(keep) fallback=count(raw.fallback[keep]) missing=length(cells)-length(keep)
    output_path
end

function write_nasa_timeline!(; output_dir::AbstractString=nasa_output_dir())
    paths = [joinpath(output_dir, "planet_mcd43c4_$(CONFIG["year"])_month_$(lpad(month, 2, '0')).arrow") for month in CONFIG["months"]]
    available = findall(isfile, paths)
    (isempty(available) || first(available) != 1) && return nothing
    complete = length(available) == length(paths)
    final_month = complete ? 12 : 1
    metadata_path = joinpath(output_dir, "planet_mcd43c4_$(CONFIG["year"])_month_01.json")
    write_json(metadata_path, Dict(
        "t" => "Global land — $(CONFIG["year"]), month {controls.month}",
        "c" => "NASA LP DAAC MCD43C4 V061; RGB bands 1, 4, 3; each selected date is a 16-day Terra/Aqua composite; fill-centre fallbacks use the nearest valid pixel whose centre is closer to this H3 centre than to every adjacent H3 centre; pixel offsets are in the data",
        "animate" => complete,
        "controls" => Dict("month" => Dict(
            "label" => "Month", "type" => "number", "default" => 1, "min" => 1,
            "max" => final_month, "step" => 1,
            "encode" => "value => String(value).padStart(2, '0')",
            "animate" => Dict("start" => 1, "end" => final_month, "step" => 1, "step_rate" => 1),
        )),
        "onchange" => Dict(
            "url" => "/data/planet_mcd43c4_$(CONFIG["year"])_month_{controls.month}.arrow",
            "format" => "auto",
        ),
    ))
    metadata_path
end

function process_nasa_month!(month::Integer, cells::AbstractVector{Cell}=load_or_create_land_cells();
                             data_dir::AbstractString=nasa_data_dir(),
                             checkpoint_dir::AbstractString=nasa_checkpoint_dir(),
                             output_dir::AbstractString=nasa_output_dir())
    month in CONFIG["months"] || throw(ArgumentError("month must be in $(CONFIG["months"])"))
    path = nasa_month_path(month; data_dir)
    is_hdf4_file(path) || error("NASA HDF file is missing or invalid: $path. Run bin/download_nasa_data.jl $month")
    rows = clamp.(floor.(Int, (90.0 .- getfield.(cells, :lat)) ./ 0.05), 0, NASA_ROWS - 1)
    cols = mod.(floor.(Int, (getfield.(cells, :lon) .+ 180.0) ./ 0.05), NASA_COLS)
    raster_red = read_full_band(path, NASA_BANDS[1])
    raster_green = read_full_band(path, NASA_BANDS[2])
    raster_blue = read_full_band(path, NASA_BANDS[3])

    checkpoint = checkpoint_path(month; checkpoint_dir)
    raw = if isfile(checkpoint)
        @info "Reusing NASA sampling checkpoint" month checkpoint
        load_month_checkpoint(checkpoint, cells)
    else
        sample_centres(cells, rows, cols, raster_red, raster_green, raster_blue)
    end
    missing_centres = findall(i -> !valid_rgb(raw.red, raw.green, raw.blue, i), eachindex(cells))
    fallback, offset_row, offset_col = falses(length(cells)), zeros(Int16, length(cells)), zeros(Int16, length(cells))
    recovered = 0
    pixel_lats = 90.0 .- ((0:(NASA_ROWS - 1)) .+ 0.5) .* 0.05
    pixel_lons = -180.0 .+ ((0:(NASA_COLS - 1)) .+ 0.5) .* 0.05
    pixel_sin_lat, pixel_cos_lat = sind.(pixel_lats), cosd.(pixel_lats)
    pixel_sin_lon, pixel_cos_lon = sind.(pixel_lons), cosd.(pixel_lons)
    for (searched, i) in enumerate(missing_centres)
        recovered += nearest_valid_pixel!(i, cells, rows, cols, raw.red, raw.green, raw.blue,
            fallback, offset_row, offset_col, raster_red, raster_green, raster_blue,
            pixel_sin_lat, pixel_cos_lat, pixel_sin_lon, pixel_cos_lon)
        searched % 10000 == 0 && @info "Searching within H3 centre regions" month searched total=length(missing_centres) recovered
    end
    raw = (; raw.red, raw.green, raw.blue, fallback, offset_row, offset_col)
    write_arrow_atomic(checkpoint, (
        h3_hi=UInt32[cell.h3_hi for cell in cells], h3_lo=UInt32[cell.h3_lo for cell in cells],
        r_raw=raw.red, g_raw=raw.green, b_raw=raw.blue, fallback=UInt8.(raw.fallback),
        pixel_offset_row=raw.offset_row, pixel_offset_col=raw.offset_col,
    ))
    @info "Finished NASA H3 sampling" month centre_samples=length(cells) recovered still_missing=length(missing_centres)-recovered
    output_path = render_nasa_month(month, cells, raw; output_dir)
    write_nasa_timeline!(; output_dir)
    output_path
end

function process_nasa_months!(months=CONFIG["months"], cells::AbstractVector{Cell}=load_or_create_land_cells(); kwargs...)
    foreach(month -> process_nasa_month!(month, cells; kwargs...), months)
    nothing
end
