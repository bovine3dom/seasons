const NATURAL_EARTH_LAND_PATH = joinpath(PROJECT_ROOT, "cache", "natural_earth", "ne_50m_land.geojson")

function ensure_natural_earth_land_file(path::AbstractString=NATURAL_EARTH_LAND_PATH)
    isfile(path) && return path
    mkpath(dirname(path))
    temporary = path * ".download"
    @info "Downloading Natural Earth 1:50m land polygons" path
    try
        Downloads.download(CONFIG["land"]["url"], temporary)
        collection = JSON3.read(read(temporary, String))
        get(collection, "type", nothing) == "FeatureCollection" || error("Natural Earth file is not a GeoJSON FeatureCollection")
        mv(temporary, path; force=true)
    finally
        isfile(temporary) && rm(temporary; force=true)
    end
    path
end

function natural_earth_ring(points)
    coordinates = Tuple{Float64,Float64}[(Float64(point[1]), Float64(point[2])) for point in points]
    length(coordinates) >= 3 || error("Natural Earth polygon ring has fewer than 3 points")
    first(coordinates) == last(coordinates) || push!(coordinates, first(coordinates))
    coordinates
end

function point_in_ring(lon::Float64, lat::Float64, ring::Vector{Tuple{Float64,Float64}})
    inside = false
    previous = length(ring)
    for current in eachindex(ring)
        x1, y1 = ring[current]
        x2, y2 = ring[previous]
        if (y1 > lat) != (y2 > lat) && lon < (x2 - x1) * (lat - y1) / (y2 - y1) + x1
            inside = !inside
        end
        previous = current
    end
    inside
end

function land_ring_ids(points, resolution, all_cells, centers, label)
    ring = natural_earth_ring(points)
    loop = [H3API.LatLng(deg2rad(lat), deg2rad(lon)) for (lon, lat) in ring]
    cells = H3API.polygonToCells(loop, Int(resolution))
    !(cells isa H3API.H3ErrorCode) && return Set{UInt64}(cells)

    @warn "Using centre-in-polygon fallback for a Natural Earth ring" label error=H3API.describeH3Error(cells)
    if isempty(all_cells)
        append!(all_cells, h3_cells(resolution))
        append!(centers, [begin p=h3_center_deg(h); (p.lon, p.lat) end for h in all_cells])
    end
    min_lon, max_lon = extrema(first, ring)
    min_lat, max_lat = extrema(last, ring)
    selected = Set{UInt64}()
    for (i, (lon, lat)) in enumerate(centers)
        min_lon <= lon <= max_lon && min_lat <= lat <= max_lat || continue
        point_in_ring(lon, lat, ring) && push!(selected, all_cells[i])
    end
    selected
end

function natural_earth_land_ids(path::AbstractString, resolution::Integer)
    collection = JSON3.read(read(path, String))
    get(collection, "type", nothing) == "FeatureCollection" || error("Natural Earth file is not a GeoJSON FeatureCollection")
    land = Set{UInt64}()
    all_cells, centers = UInt64[], Tuple{Float64,Float64}[]
    for (feature_id, feature) in enumerate(collection["features"])
        geometry = feature["geometry"]
        geometry_type, coordinates = geometry["type"], geometry["coordinates"]
        polygons = geometry_type == "Polygon" ? (coordinates,) :
            geometry_type == "MultiPolygon" ? coordinates : error("Unsupported Natural Earth geometry $geometry_type")
        for (polygon_id, rings) in enumerate(polygons)
            label = "feature $feature_id polygon $polygon_id"
            polygon = land_ring_ids(rings[1], resolution, all_cells, centers, label)
            for hole_id in 2:length(rings)
                setdiff!(polygon, land_ring_ids(rings[hole_id], resolution, all_cells, centers, "$label hole $hole_id"))
            end
            union!(land, polygon)
        end
    end
    land
end

function land_cells(resolution::Integer=CONFIG["resolution"];
                    polygons_path::AbstractString=ensure_natural_earth_land_file())
    ids = natural_earth_land_ids(polygons_path, resolution)
    [cell_for_h3(h) for h in sort!(collect(ids))]
end

land_cells_path(resolution::Integer=CONFIG["resolution"]) =
    joinpath(PROJECT_ROOT, "cache", "cells_global_land_ne50m_r$(resolution).arrow")

function load_or_create_land_cells(resolution::Integer=CONFIG["resolution"])
    path = land_cells_path(resolution)
    if isfile(path)
        return read_cells(path)
    end
    cells = land_cells(resolution)
    write_cells(path, cells)
    cells
end
