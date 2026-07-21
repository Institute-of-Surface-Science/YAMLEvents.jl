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

function _at_directive_prologue(state::_EventIteratorState)
    parser_state = state.stream.state
    return parser_state === YAML.parse_implicit_document_start ||
           parser_state === YAML.parse_document_start
end

function _has_unknown_directive(state::_EventIteratorState)
    return state.next_unknown_directive <=
           length(state.mark_converter.unknown_directives)
end

function _scan_directive_prologue!(state::_EventIteratorState)
    state.directive_prologue_scanned && return nothing
    converter = state.mark_converter
    converter.tokenstream === nothing && return nothing
    _at_directive_prologue(state) || return nothing

    # Stop as soon as there is an event to yield. Apart from preserving the
    # iterator's lazy contract, this bounds the pending-directive buffer instead
    # of tokenizing an arbitrarily large prologue up front.
    while !_has_unknown_directive(state)
        token = _next_mapping_token!(converter)
        if token === nothing
            state.directive_prologue_scanned = true
            break
        end
        _record_mapping_token!(converter, token)
        if !(token isa Union{YAML.StreamStartToken, YAML.ByteOrderMarkToken,
                             YAML.DocumentEndToken, YAML.DirectiveToken})
            state.directive_prologue_scanned = true
            break
        end
    end
    return nothing
end

function _next_unknown_directive!(state::_EventIteratorState)
    directives = state.mark_converter.unknown_directives
    _has_unknown_directive(state) || return nothing
    event = directives[state.next_unknown_directive]
    state.next_unknown_directive += 1
    if state.next_unknown_directive > length(directives)
        empty!(directives)
        state.next_unknown_directive = 1
    end
    if state.unknown_directive_mode === :error
        state.done = true
        throw(ScannerError("while scanning a directive", event.start_mark,
                           "found unknown directive \"$(event.name)\"",
                           event.start_mark))
    end
    return event
end

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
    _scan_directive_prologue!(state)
    directive = _next_unknown_directive!(state)
    directive === nothing || return directive, nothing

    event = _forward!(state)
    event === nothing && return nothing

    # The internal parser treats an explicit document end (`...`) as the end
    # of its EventStream. Resume it while suppressing the artificial stream
    # boundary so this public iterator represents the complete YAML stream.
    if event isa YAML.StreamEndEvent &&
       state.previous_backend_event isa DocumentEndEvent &&
       state.previous_backend_event.explicit
        event = _resume_after_explicit_document!(state)
    end

    if event === nothing
        state.done = true
        return nothing
    end

    event = _convert_event(state, event)
    state.previous_backend_event = event
    event isa DocumentEndEvent && (state.directive_prologue_scanned = false)
    state.done = event isa StreamEndEvent
    return event, nothing
end

"""
    parse_events(input::Union{AbstractString, IO}; unknown_directives=:event)
        -> YAMLEventIterator

Parse `input` into a forward-only stream of [`Event`](@ref) objects without
constructing Julia values.

YAMLEvents implements YAML 1.1 syntax. An explicit directive declaring a newer
YAML version raises [`ParserError`](@ref) as the iterator advances.
Unknown directives produce [`UnknownDirectiveEvent`](@ref) objects by default.
Each event precedes its document-start event and retains the exact text after
the directive name without producing a log message. Pass
`unknown_directives=:error` to reject unknown directives with a
[`ScannerError`](@ref) instead.

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
function _unknown_directive_mode(mode)
    mode in (:event, :error) ||
        throw(ArgumentError("unknown_directives must be :event or :error"))
    return mode
end

function _parse_events(input::_PreparedInput, unknown_directives::Symbol)
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
                               Dict{NTuple{3, UInt64}, Tuple{String, Mark}}(),
                               UnknownDirectiveEvent[], false, false)
    state = _EventIteratorState(tokenstream, YAML.EventStream(tokenstream), converter,
                                input.encoding, unknown_directives, false, 1, nothing, false)
    return YAMLEventIterator(state)
end

function parse_events(input::IO; unknown_directives = :event)
    mode = _unknown_directive_mode(unknown_directives)
    return _parse_events(_prepare_input(input), mode)
end

function parse_events(input::AbstractString; unknown_directives = :event)
    mode = _unknown_directive_mode(unknown_directives)
    return _parse_events(_prepare_input(input), mode)
end
