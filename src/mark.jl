"""
    Mark

A position between characters in the original YAML input.

`index` and `column` are zero-based character offsets. `line` is one-based.
"""
struct Mark
    index::UInt64
    line::UInt64
    column::UInt64
end

function Base.show(io::IO, mark::Mark)
    print(io, "line ", mark.line, ", column ", mark.column)
end
