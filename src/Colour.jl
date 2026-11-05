channel_to_u8(raw::Missing; kwargs...) = missing

function channel_to_u8(raw::Real; low=CONFIG["visual_min"], high=CONFIG["visual_max"],
                       gamma=CONFIG["visual_gamma"])::UInt8
    high > low || throw(ArgumentError("visual_max must be greater than visual_min"))
    gamma > 0 || throw(ArgumentError("visual_gamma must be positive"))
    value = clamp((Float64(raw) - low) / (high - low), 0.0, 1.0)
    UInt8(round(Int, 255 * value^(1 / gamma)))
end
