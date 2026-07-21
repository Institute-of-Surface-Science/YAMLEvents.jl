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

function _forward!(state::_EventIteratorState)
    return _with_error_conversion(state) do
        YAML.forward!(state.stream)
    end
end

function _resume_after_explicit_document!(state::_EventIteratorState)
    # YAML.jl stops tokenization at every explicit document-end marker. Resume
    # the existing parser at its explicit-document state, skipping any repeated
    # suffix markers without pretending the following document is the first
    # (and therefore potentially implicit) document in a new stream.
    state.stream.end_of_stream = nothing
    _with_error_conversion(state) do
        while true
            state.tokenstream.done = false
            token = YAML.peek(state.tokenstream)
            token isa YAML.DocumentEndToken || break
            YAML.forward!(state.tokenstream)
        end
        if token isa YAML.ByteOrderMarkToken
            YAML.forward!(state.tokenstream)
            token = YAML.peek(state.tokenstream)
        end
        if !(token isa
             Union{YAML.DirectiveToken, YAML.DocumentStartToken, YAML.StreamEndToken})
            problem_mark = _convert_mark(state, YAML.firstmark(token))
            throw(ParserError(nothing, nothing,
                              "expected '<document start>', but found $(typeof(token))",
                              problem_mark, nothing))
        end
    end

    state.stream.state = YAML.parse_document_start
    return _forward!(state)
end

function Base.iterate(iterator::YAMLEventIterator, _ = nothing)
    state = iterator._state
    state.done && return nothing
    event = _forward!(state)
    event === nothing && return nothing

    # The internal parser treats an explicit document end (`...`) as the end
    # of its EventStream. Resume it while suppressing the artificial stream
    # boundary so this public iterator represents the complete YAML stream.
    if event isa YAML.StreamEndEvent &&
       state.previous_event isa DocumentEndEvent &&
       state.previous_event.explicit
        event = _resume_after_explicit_document!(state)
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

YAMLEvents implements YAML 1.1 syntax. An explicit directive declaring a newer
YAML version raises [`ParserError`](@ref) as the iterator advances.

The event stream preserves document boundaries, scalar styles, explicit tags,
anchors, aliases, collection styles, and source marks. This is useful for tools
that need to inspect YAML syntax before aliases, tags, or duplicate mapping keys
are resolved during construction.

An `IO` input is read when the iterator is created, so seekable and forward-only
streams are both supported. Invalid encoded input raises [`EncodingError`](@ref)
while the iterator is created. Characters whose invalidity can be established
during input validation raise [`ScannerError`](@ref) during the same step. Other
malformed decoded YAML raises only [`ScannerError`](@ref) or [`ParserError`](@ref)
as the iterator advances. Internal failures that cannot be attributed to source
text are rethrown rather than converted to input errors.

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
    _validate_source_characters(input)
    tokenstream = YAML.TokenStream(IOBuffer(input.source))
    tokenstream.index == 1 || error("unsupported YAML backend index convention")
    needs_mapping = any(char -> char in ('\ufeff', '\'', '"', '\\', '%'), input.source)
    mapping_source = needs_mapping ? input.source : nothing
    mapping_tokenstream = needs_mapping ? YAML.TokenStream(IOBuffer(input.source)) : nothing
    line_start_positions = needs_mapping ? _line_start_positions(input.source) : nothing
    converter = _MarkConverter(mapping_source, input.newline_corrections,
                               input.character_count, line_start_positions,
                               mapping_tokenstream, 0, UInt64[], UInt64[],
                               firstindex(input.source), 0,
                               Dict{NTuple{3, UInt64}, Tuple{UInt64, UInt64}}(),
                               Dict{NTuple{3, UInt64}, Tuple{String, Mark}}(), false, false)
    state = _EventIteratorState(tokenstream, YAML.EventStream(tokenstream), converter,
                                input.encoding, nothing, false)
    return YAMLEventIterator(state)
end

parse_events(input::IO) = _parse_events(_prepare_input(input))
parse_events(input::AbstractString) = _parse_events(_prepare_input(input))
