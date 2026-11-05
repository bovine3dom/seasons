function write_arrow_atomic(path::AbstractString, table)
    mkpath(dirname(path))
    temporary = path * ".tmp"
    Arrow.write(temporary, table; compress=nothing, dictencode=false)
    mv(temporary, path; force=true)
    path
end

function write_json(path::AbstractString, value)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, JSON3.write(value))
        write(io, '\n')
    end
    path
end
