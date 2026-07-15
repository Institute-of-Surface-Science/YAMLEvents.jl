mutable struct _EventIteratorState
    tokenstream::YAML.TokenStream
    stream::YAML.EventStream
    index_map::Vector{UInt64}
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

function _convert_mark(state::_EventIteratorState, mark::YAML.Mark)
    normalized_index = Int(mark.index ÷ 2)
    checkbounds(Bool, state.index_map, normalized_index + 1) ||
        error("YAML backend returned an invalid source index $(mark.index)")
    return Mark(state.index_map[normalized_index + 1], mark.line, mark.column)
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
streams are both supported. Malformed input raises [`ScannerError`](@ref) or
[`ParserError`](@ref).

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
    state = _EventIteratorState(tokenstream, YAML.EventStream(tokenstream), input.index_map,
                                input.encoding, nothing, false)
    return YAMLEventIterator(state)
end

parse_events(input::IO) = _parse_events(_prepare_input(input))
parse_events(input::AbstractString) = _parse_events(_prepare_input(input))
