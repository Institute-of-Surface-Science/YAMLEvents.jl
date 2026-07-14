mutable struct _EventIteratorState
    tokenstream::TokenStream
    stream::EventStream
    previous_event::Union{Event, Nothing}
    done::Bool
end

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

function iterate(iterator::YAMLEventIterator, _ = nothing)
    state = iterator._state
    state.done && return nothing
    event = forward!(state.stream)
    event === nothing && return nothing

    # The internal parser treats an explicit document end (`...`) as the end
    # of its EventStream. Restart it while suppressing the artificial stream
    # boundary so this public iterator represents the complete YAML stream.
    if event isa StreamEndEvent &&
       state.previous_event isa DocumentEndEvent &&
       state.previous_event.explicit
        reset!(state.tokenstream)
        state.stream = EventStream(state.tokenstream)
        @assert forward!(state.stream) isa StreamStartEvent
        event = forward!(state.stream)
    end

    if event === nothing
        state.done = true
        return nothing
    end

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

The returned iterator borrows an `IO` input, which must remain open while the
iterator is consumed. Malformed input raises [`ScannerError`](@ref) or
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
function parse_events(input::IO)
    tokenstream = TokenStream(input)
    state = _EventIteratorState(tokenstream, EventStream(tokenstream), nothing, false)
    return YAMLEventIterator(state)
end

parse_events(input::AbstractString) = parse_events(IOBuffer(input))
