# YAML.jl 0.4.16 advances its source index twice for most characters, once for
# tokenized BOMs, and not at all in a handful of quoted-scalar and tag-URI
# scanner paths. Replay only inputs containing those constructs and retain
# sparse corrections so public marks still refer to the original characters.
mutable struct _MarkConverter
    source::Union{String, Nothing}
    newline_corrections::Vector{UInt64}
    character_count::UInt64
    tokenstream::Union{YAML.TokenStream, Nothing}
    scanned_index::UInt64
    bom_end_indices::Vector{UInt64}
    bom_lines::Vector{UInt64}
    skipped_indices::Vector{UInt64}
    skipped_lines::Vector{UInt64}
    source_cursor::Int
    source_position::UInt64
    mark_overrides::Dict{NTuple{3, UInt64}, Tuple{UInt64, UInt64}}
    reset_pending::Bool
    done::Bool
end

mutable struct _EventIteratorState
    tokenstream::YAML.TokenStream
    stream::YAML.EventStream
    mark_converter::_MarkConverter
    encoding::String
    previous_event::Union{Event, Nothing}
    done::Bool
end

# YAML.jl 0.4.16 has no public event iterator. Keep all coupling to its parser
# internals in this file; Project.toml pins the exact backend version.

"""
    YAMLEventIterator

A forward-only iterator over the syntactic events in a YAML stream.

Create an iterator with [`parse_events`](@ref). Parser errors are raised when
the iterator reaches malformed input. Each iterator may be consumed only once.
"""
struct YAMLEventIterator
    _state::_EventIteratorState
end

Base.IteratorSize(::Type{YAMLEventIterator}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{YAMLEventIterator}) = Base.HasEltype()
Base.eltype(::Type{YAMLEventIterator}) = Event

_mark_key(mark::YAML.Mark) = (mark.index, mark.line, mark.column)

function _normalized_index(converter::_MarkConverter, backend_index::UInt64)
    bom_count = searchsortedlast(converter.bom_end_indices, backend_index)
    skipped_count = searchsortedlast(converter.skipped_indices, backend_index)
    adjusted_index = backend_index - 1 + UInt64(bom_count + 2 * skipped_count)
    iseven(adjusted_index) ||
        error("YAML backend returned an unsupported source index $backend_index")
    normalized_index = adjusted_index ÷ 2
    normalized_index <= converter.character_count ||
        error("YAML backend returned an invalid source index $backend_index")
    return normalized_index
end

function _source_index!(converter::_MarkConverter, target_position::UInt64)
    target_position >= converter.source_position ||
        error("YAML backend returned source marks out of order")
    source = converter.source
    while converter.source_position < target_position
        converter.source_cursor = nextind(source, converter.source_cursor)
        converter.source_position += 1
    end
    return converter.source_cursor
end

_is_line_break(char::Char) = char in ('\n', '\u0085', '\u2028', '\u2029')
_is_inline_space(char::Char) = char == ' ' || char == '\t'

function _advance_normal(source::String, source_index::Int, source_position::UInt64,
                         backend_index::UInt64, line::UInt64)
    char = source[source_index]
    return nextind(source, source_index), source_position + 1, backend_index + 2,
           line + UInt64(_is_line_break(char))
end

function _advance_skipped!(converter::_MarkConverter, source_index::Int,
                           source_position::UInt64, backend_index::UInt64, line::UInt64)
    push!(converter.skipped_indices, backend_index)
    push!(converter.skipped_lines, line)
    return nextind(converter.source, source_index), source_position + 1
end

function _record_flow_breaks!(converter::_MarkConverter, source_index::Int,
                              source_position::UInt64, backend_index::UInt64, line::UInt64)
    source = converter.source
    while true
        while source_index <= ncodeunits(source) && _is_inline_space(source[source_index])
            source_index, source_position = _advance_skipped!(converter, source_index,
                                                              source_position,
                                                              backend_index, line)
        end
        if source_index <= ncodeunits(source) && _is_line_break(source[source_index])
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
                                                                                 line)
        else
            return source_index, source_position, backend_index, line
        end
    end
end

function _record_quoted_corrections!(converter::_MarkConverter, token::YAML.ScalarToken)
    start_mark = YAML.firstmark(token)
    end_mark = YAML.lastmark(token)
    source_position = _normalized_index(converter, start_mark.index)
    source_index = _source_index!(converter, source_position)
    source = converter.source
    style = token.style
    source[source_index] == style || error("could not align YAML quoted scalar source")
    backend_index = start_mark.index
    line = start_mark.line
    source_index, source_position, backend_index, line = _advance_normal(source,
                                                                         source_index,
                                                                         source_position,
                                                                         backend_index,
                                                                         line)

    while source_index <= ncodeunits(source)
        char = source[source_index]
        next_index = nextind(source, source_index)
        next_char = next_index <= ncodeunits(source) ? source[next_index] : '\0'

        if char == style && !(style == '\'' && next_char == '\'')
            break
        elseif _is_inline_space(char)
            while source_index <= ncodeunits(source) &&
                  _is_inline_space(source[source_index])
                source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                     source_index,
                                                                                     source_position,
                                                                                     backend_index,
                                                                                     line)
            end
            if source_index <= ncodeunits(source) && _is_line_break(source[source_index])
                source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                     source_index,
                                                                                     source_position,
                                                                                     backend_index,
                                                                                     line)
                source_index, source_position, backend_index,
                line = _record_flow_breaks!(converter, source_index, source_position,
                                            backend_index, line)
            end
        elseif _is_line_break(char)
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
                                                                                 line)
            source_index, source_position, backend_index,
            line = _record_flow_breaks!(converter, source_index, source_position,
                                        backend_index, line)
        elseif style == '\'' && char == '\'' && next_char == '\''
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
                                                                                 line)
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
                                                                                 line)
        elseif (style == '"' && char == '\'') ||
               (style == '\'' && (char == '"' || char == '\\'))
            source_index, source_position = _advance_skipped!(converter, source_index,
                                                              source_position,
                                                              backend_index, line)
        elseif style == '"' && char == '\\'
            source_index, source_position = _advance_skipped!(converter, source_index,
                                                              source_position,
                                                              backend_index, line)
            escaped = source[source_index]
            if haskey(YAML.ESCAPE_REPLACEMENTS, escaped)
                source_index, source_position = _advance_skipped!(converter, source_index,
                                                                  source_position,
                                                                  backend_index, line)
            elseif haskey(YAML.ESCAPE_CODES, escaped)
                digits = YAML.ESCAPE_CODES[escaped]
                source_index, source_position = _advance_skipped!(converter, source_index,
                                                                  source_position,
                                                                  backend_index, line)
                for _ in 1:digits
                    source_index, source_position, backend_index,
                    line = _advance_normal(source, source_index, source_position,
                                           backend_index, line)
                end
            elseif _is_line_break(escaped)
                source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                     source_index,
                                                                                     source_position,
                                                                                     backend_index,
                                                                                     line)
                source_index, source_position, backend_index,
                line = _record_flow_breaks!(converter, source_index, source_position,
                                            backend_index, line)
            else
                error("could not align YAML double-quoted escape")
            end
        else
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
                                                                                 line)
        end
    end

    source_index <= ncodeunits(source) || error("unterminated YAML quoted scalar")
    source_index, source_position, backend_index, line = _advance_normal(source,
                                                                         source_index,
                                                                         source_position,
                                                                         backend_index,
                                                                         line)
    backend_index == end_mark.index || error("could not align YAML quoted scalar mark")
    converter.source_cursor = source_index
    converter.source_position = source_position
    return nothing
end

function _record_uri_corrections!(converter::_MarkConverter, token;
                                  initial_percent_is_normal::Bool = false)
    start_mark = YAML.firstmark(token)
    end_mark = YAML.lastmark(token)
    source_position = _normalized_index(converter, start_mark.index)
    source_index = _source_index!(converter, source_position)
    source = converter.source
    backend_index = start_mark.index
    line = start_mark.line
    first_character = true

    while backend_index < end_mark.index
        source_index <= ncodeunits(source) || error("could not align YAML tag source")
        char = source[source_index]
        if char == '%' && !(initial_percent_is_normal && first_character)
            source_index, source_position = _advance_skipped!(converter, source_index,
                                                              source_position,
                                                              backend_index, line)
        else
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
                                                                                 line)
        end
        first_character = false
    end

    backend_index == end_mark.index || error("could not align YAML tag mark")
    converter.source_cursor = source_index
    converter.source_position = source_position
    return nothing
end

function _record_token_corrections!(converter::_MarkConverter, token)
    if token isa YAML.ByteOrderMarkToken
        end_mark = YAML.lastmark(token)
        push!(converter.bom_end_indices, end_mark.index)
        push!(converter.bom_lines, end_mark.line)
    elseif token isa YAML.ScalarToken && token.style in ('\'', '"')
        _record_quoted_corrections!(converter, token)
    elseif token isa YAML.TagToken
        _record_uri_corrections!(converter, token)
    elseif token isa YAML.DirectiveToken && token.name == "TAG"
        _record_uri_corrections!(converter, token; initial_percent_is_normal = true)
    end
    return nothing
end

function _source_position_at_input(converter::_MarkConverter)
    buffered_input = converter.tokenstream.input
    byte_position = position(buffered_input.input)
    fetched_characters = if byte_position == 0
        0
    else
        length(SubString(converter.source, firstindex(converter.source),
                         prevind(converter.source, byte_position + 1)))
    end
    available_characters = count(!=('\0'),
                                 @view(buffered_input.buffer[(buffered_input.offset + 1):(buffered_input.offset + buffered_input.avail)]))
    return UInt64(fetched_characters - available_characters)
end

function _source_column(source::String, target_position::UInt64)
    source_index = firstindex(source)
    position = UInt64(0)
    column = UInt64(0)
    while position < target_position
        char = source[source_index]
        column = _is_line_break(char) ? 0 : column + 1
        source_index = nextind(source, source_index)
        position += 1
    end
    return column
end

function _record_error_override!(converter::_MarkConverter, exception::YAML.ScannerError)
    # Scanner errors may occur between two identical backend indices after a
    # skipped character. The replay scanner's buffered-input cursor is the only
    # unambiguous position for that problem mark.
    mark = exception.problem_mark
    source_position = _source_position_at_input(converter)
    converter.mark_overrides[_mark_key(mark)] = (source_position,
                                                 _source_column(converter.source,
                                                                source_position))
    return nothing
end

function _next_mapping_token!(converter::_MarkConverter)
    while true
        token = try
            Logging.with_logger(Logging.NullLogger()) do
                YAML.forward!(converter.tokenstream)
            end
        catch exception
            if exception isa YAML.ScannerError
                _record_error_override!(converter, exception)
                converter.done = true
                return nothing
            end
            rethrow()
        end

        if token === nothing && converter.reset_pending
            YAML.reset!(converter.tokenstream)
            converter.reset_pending = false
        elseif token === nothing
            converter.done = true
            return nothing
        else
            converter.reset_pending = token isa YAML.DocumentEndToken
            return token
        end
    end
end

function _scan_mark_mapping!(converter::_MarkConverter, backend_index::UInt64)
    while !converter.done && converter.scanned_index < backend_index
        token = _next_mapping_token!(converter)
        token === nothing && break
        _record_token_corrections!(converter, token)
        end_mark = YAML.lastmark(token)
        converter.scanned_index = max(converter.scanned_index, end_mark.index)
    end
    return nothing
end

function _convert_mark(state::_EventIteratorState, mark::YAML.Mark)
    converter = state.mark_converter
    converter.tokenstream === nothing || _scan_mark_mapping!(converter, mark.index)

    override = get(converter.mark_overrides, _mark_key(mark), nothing)
    normalized_index = override === nothing ? _normalized_index(converter, mark.index) :
                       override[1]

    correction_count = searchsortedlast(converter.newline_corrections, normalized_index)
    original_index = normalized_index + UInt64(correction_count)
    bom_column_correction = count(eachindex(converter.bom_end_indices)) do index
        converter.bom_end_indices[index] <= mark.index &&
            converter.bom_lines[index] == mark.line
    end
    skipped_column_correction = count(eachindex(converter.skipped_indices)) do index
        converter.skipped_indices[index] <= mark.index &&
            converter.skipped_lines[index] == mark.line
    end
    column = override === nothing ?
             mark.column + UInt64(bom_column_correction + skipped_column_correction) :
             override[2]
    return Mark(original_index, mark.line, column)
end

_convert_mark(::_EventIteratorState, ::Nothing) = nothing

function _marks(state, event)
    return _convert_mark(state, event.start_mark), _convert_mark(state, event.end_mark)
end

function _convert_event(state, event::YAML.StreamStartEvent)
    return StreamStartEvent(_marks(state, event)..., state.encoding)
end

_convert_event(state, event::YAML.StreamEndEvent) = StreamEndEvent(_marks(state, event)...)

function _convert_event(state, event::YAML.DocumentStartEvent)
    tags = event.tags === nothing ? nothing : copy(event.tags)
    return DocumentStartEvent(_marks(state, event)..., event.explicit, event.version, tags)
end

function _convert_event(state, event::YAML.DocumentEndEvent)
    return DocumentEndEvent(_marks(state, event)..., event.explicit)
end

function _convert_event(state, event::YAML.AliasEvent)
    return AliasEvent(_marks(state, event)..., event.anchor)
end

function _convert_event(state, event::YAML.ScalarEvent)
    implicit = (Bool(event.implicit[1]), Bool(event.implicit[2]))
    return ScalarEvent(_marks(state, event)..., event.anchor, event.tag, implicit,
                       event.value, event.style)
end

function _convert_event(state, event::YAML.SequenceStartEvent)
    return SequenceStartEvent(_marks(state, event)..., event.anchor, event.tag,
                              event.implicit, event.flow_style)
end

function _convert_event(state, event::YAML.SequenceEndEvent)
    SequenceEndEvent(_marks(state, event)...)
end

function _convert_event(state, event::YAML.MappingStartEvent)
    return MappingStartEvent(_marks(state, event)..., event.anchor, event.tag,
                             event.implicit, event.flow_style)
end

function _convert_event(state, event::YAML.MappingEndEvent)
    MappingEndEvent(_marks(state, event)...)
end

function _convert_error(state, error::YAML.ScannerError)
    return ScannerError(error.context, _convert_mark(state, error.context_mark),
                        error.problem, _convert_mark(state, error.problem_mark))
end

function _convert_error(state, error::YAML.ParserError)
    return ParserError(error.context, _convert_mark(state, error.context_mark),
                       error.problem, _convert_mark(state, error.problem_mark), error.note)
end

function _forward!(state::_EventIteratorState)
    try
        return YAML.forward!(state.stream)
    catch exception
        if exception isa Union{YAML.ScannerError, YAML.ParserError}
            throw(_convert_error(state, exception))
        end
        rethrow()
    end
end

function Base.iterate(iterator::YAMLEventIterator, _ = nothing)
    state = iterator._state
    state.done && return nothing
    event = _forward!(state)
    event === nothing && return nothing

    # The internal parser treats an explicit document end (`...`) as the end
    # of its EventStream. Restart it while suppressing the artificial stream
    # boundary so this public iterator represents the complete YAML stream.
    if event isa YAML.StreamEndEvent &&
       state.previous_event isa DocumentEndEvent &&
       state.previous_event.explicit
        YAML.reset!(state.tokenstream)
        state.stream = YAML.EventStream(state.tokenstream)
        @assert _forward!(state) isa YAML.StreamStartEvent
        event = _forward!(state)
    end

    if event === nothing
        state.done = true
        return nothing
    end

    event = _convert_event(state, event)
    state.previous_event = event
    state.done = event isa StreamEndEvent
    return event, nothing
end

"""
    parse_events(input::Union{AbstractString, IO}) -> YAMLEventIterator

Parse `input` into a forward-only stream of [`Event`](@ref) objects without
constructing Julia values.

The event stream preserves document boundaries, scalar styles, explicit tags,
anchors, aliases, collection styles, and source marks. This is useful for tools
that need to inspect YAML syntax before aliases, tags, or duplicate mapping keys
are resolved during construction.

An `IO` input is read when the iterator is created, so seekable and forward-only
streams are both supported. Invalid encoded byte input raises
[`EncodingError`](@ref) while the iterator is created. YAML syntax errors raise
[`ScannerError`](@ref) or [`ParserError`](@ref) as the iterator advances.

# Example

```jldoctest
julia> events = collect(YAMLEvents.parse_events("key: [value]"));

julia> [event.value for event in events if event isa YAMLEvents.ScalarEvent]
2-element Vector{String}:
 "key"
 "value"

julia> first(event for event in events if event isa YAMLEvents.SequenceStartEvent).flow_style
true
```
"""
function _parse_events(input::_PreparedInput)
    pkgversion(YAML) == v"0.4.16" || error("YAMLEvents requires YAML.jl 0.4.16")
    tokenstream = YAML.TokenStream(IOBuffer(input.source))
    tokenstream.index == 1 || error("unsupported YAML backend index convention")
    needs_mapping = any(char -> char in ('\ufeff', '\'', '"', '\\', '%'), input.source)
    mapping_source = needs_mapping ? input.source : nothing
    mapping_tokenstream = needs_mapping ? YAML.TokenStream(IOBuffer(input.source)) : nothing
    converter = _MarkConverter(mapping_source, input.newline_corrections,
                               input.character_count, mapping_tokenstream, 0, UInt64[],
                               UInt64[], UInt64[], UInt64[], firstindex(input.source), 0,
                               Dict{NTuple{3, UInt64}, Tuple{UInt64, UInt64}}(), false,
                               false)
    state = _EventIteratorState(tokenstream, YAML.EventStream(tokenstream), converter,
                                input.encoding, nothing, false)
    return YAMLEventIterator(state)
end

parse_events(input::IO) = _parse_events(_prepare_input(input))
parse_events(input::AbstractString) = _parse_events(_prepare_input(input))
