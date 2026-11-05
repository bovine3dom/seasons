using Arrow
using H3Seasons
using JSON3
using Random
using Test

const API = H3Seasons.H3API

@testset "H3 cells and split IDs" begin
    ids = H3Seasons.h3_cells(4)
    @test length(ids) == 288_122
    @test length(unique(ids)) == length(ids)
    @test all(API.isValidCell, ids)
    Random.seed!(42)
    pentagon = first(filter(API.isPentagon, ids))
    for h in vcat(rand(ids, 100), pentagon)
        halves = H3Seasons.split_h3(h)
        @test H3Seasons.join_h3(halves.hi, halves.lo) == h
        @test API.h3ToString(h) == API.h3ToString(H3Seasons.join_h3(halves.hi, halves.lo))
    end
    known = parse(UInt64, "8928308280fffff"; base=16)
    center = H3Seasons.h3_center_deg(known)
    @test center.lat ≈ 37.7767 atol=0.01
    @test center.lon ≈ -122.4185 atol=0.01
end

@testset "Natural Earth land mask" begin
    inside = API.latLngToCell(API.LatLng(deg2rad(37.7), deg2rad(-122.4)), 4)
    hole = H3Seasons.h3_center_deg(inside)
    outside = API.latLngToCell(API.LatLng(0.0, 0.0), 4)
    rectangle(west, south, east, north) = [[west, south], [east, south], [east, north], [west, north], [west, south]]
    feature = Dict("type" => "Feature", "properties" => Dict(), "geometry" => Dict(
        "type" => "Polygon", "coordinates" => [
            rectangle(-124.0, 36.0, -121.0, 40.0),
            rectangle(hole.lon - 0.1, hole.lat - 0.1, hole.lon + 0.1, hole.lat + 0.1),
        ],
    ))
    mktempdir() do directory
        path = joinpath(directory, "land.geojson")
        write(path, JSON3.write(Dict("type" => "FeatureCollection", "features" => [feature])))
        cells = H3Seasons.land_cells(4; polygons_path=path)
        ids = Set(cell.h3 for cell in cells)
        @test inside ∉ ids
        @test outside ∉ ids
    end
end

@testset "NASA source and HDF cache" begin
    files = H3Seasons.nasa_source_files()
    @test length(files) == 12
    @test all(name -> startswith(name, "MCD43C4.A2025") && endswith(name, ".hdf"), files)
    mktempdir() do directory
        path = joinpath(directory, "valid.hdf")
        write(path, UInt8[0x0e, 0x03, 0x13, 0x01])
        @test H3Seasons.is_hdf4_file(path)
        write(path, "not an HDF")
        @test !H3Seasons.is_hdf4_file(path)
    end
end

@testset "Colour transfer" begin
    @test H3Seasons.channel_to_u8(0) == 0x00
    @test H3Seasons.channel_to_u8(4000) == 0xff
    @test H3Seasons.channel_to_u8(-100) == 0x00
    @test H3Seasons.channel_to_u8(5000) == 0xff
end

@testset "Checkpoint and H3-MON Arrow output" begin
    h = parse(UInt64, "8928308280fffff"; base=16)
    cell = H3Seasons.cell_for_h3(h)
    raw = (
        red=Int16[1000], green=Int16[2000], blue=Int16[3000],
        fallback=BitVector([true]), offset_row=Int16[1], offset_col=Int16[-1],
    )
    mktempdir() do directory
        path = H3Seasons.render_nasa_month(1, [cell], raw; output_dir=directory)
        table = Arrow.Table(path)
        @test eltype(table.index_lower) == UInt32
        @test eltype(table.index_upper) == UInt32
        @test all(eltype(getproperty(table, channel)) == UInt8 for channel in (:r, :g, :b, :a, :fallback))
        @test table.index_lower[1] == cell.h3_lo
        @test table.index_upper[1] == cell.h3_hi
        @test table.fallback[1] == 1
        @test table.pixel_offset_row[1] == 1
        @test table.pixel_offset_col[1] == -1
        @test table.a[1] == 0xff
        metadata_path = H3Seasons.write_nasa_timeline!(; output_dir=directory)
        preview = JSON3.read(read(metadata_path, String))
        @test !preview.animate
        @test preview.controls.month.max == 1
        for month in 2:12
            touch(joinpath(directory, "planet_mcd43c4_2025_month_$(lpad(month, 2, '0')).arrow"))
        end
        H3Seasons.write_nasa_timeline!(; output_dir=directory)
        timeline = JSON3.read(read(metadata_path, String))
        @test timeline.animate
        @test timeline.controls.month.max == 12

        checkpoint = joinpath(directory, "month_01_raw.arrow")
        H3Seasons.write_arrow_atomic(checkpoint, (
            h3_hi=UInt32[cell.h3_hi], h3_lo=UInt32[cell.h3_lo],
            r_raw=Int16[1000], g_raw=Int16[2000], b_raw=Int16[3000],
            fallback=UInt8[1], pixel_offset_row=Int16[1], pixel_offset_col=Int16[-1],
        ))
        restored = H3Seasons.load_month_checkpoint(checkpoint, [cell])
        @test restored.red[1] == 32767
        @test restored.green[1] == 32767
        @test restored.blue[1] == 32767
    end
end
