# Where in the stream a particular token lies.
struct Span
    start_mark::Mark
    end_mark::Mark
end

function show(io::IO, span::Span)
    print(io, "(line, column) ∈ (", span.start_mark.line, ", ", span.start_mark.column,
          ")...(", span.end_mark.line, ", ", span.end_mark.column, ")")
end
