"""
    Mark

A position in a YAML input stream.

`index` and `column` are zero-based character offsets; `line` is one-based.
Marks identify positions between characters, so an event's `end_mark` is
normally immediately after its source text. Use `line` and `column` for
human-readable diagnostics and `index` when comparing locations in a stream.
"""
struct Mark
    index::UInt64
    line::UInt64
    column::UInt64
end

function show(io::IO, mark::Mark)
    @printf(io, "line %d, column %d", mark.line, mark.column)
end
