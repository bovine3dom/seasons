struct Cell
    h3::UInt64
    h3_hi::UInt32
    h3_lo::UInt32
    index::String
    lon::Float64
    lat::Float64
end

function h3_result(value, operation::AbstractString)
    value isa H3API.H3ErrorCode && error("$operation failed: $(H3API.describeH3Error(value))")
    value
end

split_h3(h::UInt64) = (hi=UInt32(h >> 32), lo=UInt32(h & 0xffffffff))
join_h3(hi::UInt32, lo::UInt32)::UInt64 = (UInt64(hi) << 32) | UInt64(lo)

function h3_center_deg(h::UInt64)
    point = h3_result(H3API.cellToLatLng(h), "cellToLatLng")
    (lon=rad2deg(point.lng), lat=rad2deg(point.lat))
end

function h3_cells(resolution::Integer=CONFIG["resolution"])
    roots = h3_result(H3API.getRes0Cells(), "getRes0Cells")
    cells = UInt64[]
    for root in roots
        append!(cells, h3_result(H3API.cellToChildren(root, Int(resolution)), "cellToChildren"))
    end
    expected = h3_result(H3API.getNumCells(Int(resolution)), "getNumCells")
    length(cells) == expected || error("Expected $expected H3 cells at resolution $resolution; got $(length(cells))")
    length(unique(cells)) == expected || error("H3 enumeration produced duplicate cells")
    all(H3API.isValidCell, cells) || error("H3 enumeration produced an invalid cell")
    cells
end

function cell_for_h3(h::UInt64)
    point = h3_center_deg(h)
    halves = split_h3(h)
    Cell(h, halves.hi, halves.lo, H3API.h3ToString(h), point.lon, point.lat)
end

function write_cells(path::AbstractString, cells::AbstractVector{Cell})
    table = (
        h3_hi=UInt32[cell.h3_hi for cell in cells],
        h3_lo=UInt32[cell.h3_lo for cell in cells],
        lon=Float64[cell.lon for cell in cells],
        lat=Float64[cell.lat for cell in cells],
        index=String[cell.index for cell in cells],
    )
    write_arrow_atomic(path, table)
end

function read_cells(path::AbstractString)
    table = Arrow.Table(path)
    cells = Cell[]
    for i in eachindex(table.h3_hi)
        hi, lo = UInt32(table.h3_hi[i]), UInt32(table.h3_lo[i])
        h = join_h3(hi, lo)
        index = String(table.index[i])
        H3API.h3ToString(h) == index || error("H3 ID does not match split halves in $path at row $i")
        push!(cells, Cell(h, hi, lo, index, Float64(table.lon[i]), Float64(table.lat[i])))
    end
    cells
end
