"""
    SyntaxPolicy(; document_count=nothing,
                   allow_flow_collections=true,
                   allow_anchors=true,
                   allow_aliases=true,
                   allow_tags=true,
                   allow_unknown_directives=true,
                   allow_merge_keys=true,
                   allow_duplicate_keys=true)

An opt-in policy for [`validate_events`](@ref). By default, all syntax accepted
by [`parse_events`](@ref) is allowed and the number of documents is unrestricted.

Set `document_count` to a non-negative integer to require exactly that many YAML
documents. `allow_tags` controls both explicit node tags and `%TAG` directives;
YAML version directives remain part of parser validation.

`allow_flow_collections`, `allow_anchors`, `allow_aliases`,
`allow_unknown_directives`, `allow_merge_keys`, and `allow_duplicate_keys`
independently control their corresponding event-level syntax features.
"""
struct SyntaxPolicy
    document_count::Union{Int, Nothing}
    allow_flow_collections::Bool
    allow_anchors::Bool
    allow_aliases::Bool
    allow_tags::Bool
    allow_unknown_directives::Bool
    allow_merge_keys::Bool
    allow_duplicate_keys::Bool

    function SyntaxPolicy(document_count::Union{Int, Nothing}, allow_flow_collections::Bool,
                          allow_anchors::Bool, allow_aliases::Bool, allow_tags::Bool,
                          allow_unknown_directives::Bool, allow_merge_keys::Bool,
                          allow_duplicate_keys::Bool)
        document_count === nothing ||
            document_count >= 0 ||
            throw(ArgumentError("document_count must be non-negative or nothing"))
        return new(document_count, allow_flow_collections, allow_anchors, allow_aliases,
                   allow_tags, allow_unknown_directives, allow_merge_keys,
                   allow_duplicate_keys)
    end
end

function SyntaxPolicy(; document_count::Union{Int, Nothing} = nothing,
                      allow_flow_collections::Bool = true, allow_anchors::Bool = true,
                      allow_aliases::Bool = true, allow_tags::Bool = true,
                      allow_unknown_directives::Bool = true, allow_merge_keys::Bool = true,
                      allow_duplicate_keys::Bool = true)
    return SyntaxPolicy(document_count, allow_flow_collections, allow_anchors,
                        allow_aliases, allow_tags, allow_unknown_directives,
                        allow_merge_keys, allow_duplicate_keys)
end

"""Summary returned after an event stream satisfies a [`SyntaxPolicy`](@ref)."""
struct SyntaxValidationSummary
    document_count::Int
end

"""Abstract supertype for failures caused by a [`SyntaxPolicy`](@ref)."""
abstract type SyntaxPolicyError <: Exception end

"""
    DisallowedSyntaxError

A YAML syntax feature rejected by a [`SyntaxPolicy`](@ref). `feature` is one of
`:flow_mapping`, `:flow_sequence`, `:anchor`, `:alias`, `:tag`,
`:tag_directive`, `:unknown_directive`, or `:merge_key`.
"""
struct DisallowedSyntaxError <: SyntaxPolicyError
    feature::Symbol
    mark::Mark
end

"""
A repeated direct scalar mapping key rejected by a [`SyntaxPolicy`](@ref).
`mark` identifies the duplicate and `first_mark` identifies the original key.
"""
struct DuplicateKeyError <: SyntaxPolicyError
    key::String
    mark::Mark
    first_mark::Mark
end

"""
An exact YAML document-count requirement that was not satisfied. `mark` points
to the first excess document or the end of the stream and may be `nothing` for
an event iterable without an applicable boundary event.
"""
struct DocumentCountError <: SyntaxPolicyError
    expected::Int
    actual::Int
    mark::Union{Mark, Nothing}
end

function Base.showerror(io::IO, error::DisallowedSyntaxError)
    feature = replace(String(error.feature), '_' => ' ')
    print(io, "YAML syntax policy disallows ", feature, " at ", error.mark)
end

function Base.showerror(io::IO, error::DuplicateKeyError)
    print(io, "duplicate scalar mapping key ")
    show(io, error.key)
    print(io, " at ", error.mark, "; first defined at ", error.first_mark)
end

function Base.showerror(io::IO, error::DocumentCountError)
    expected_label = error.expected == 1 ? "document" : "documents"
    actual_label = error.actual == 1 ? "document" : "documents"
    print(io, "expected ", error.expected, " YAML ", expected_label, ", found ",
          error.actual, " ", actual_label)
    error.mark === nothing || print(io, " at ", error.mark)
end

abstract type _SyntaxCollectionState end

mutable struct _SyntaxMappingState <: _SyntaxCollectionState
    expecting_key::Bool
    keys::Union{Dict{String, Mark}, Nothing}
end

struct _SyntaxSequenceState <: _SyntaxCollectionState end

function _disallowed_syntax(feature::Symbol, event::Event)
    throw(DisallowedSyntaxError(feature, event.start_mark))
end

function _validate_node_metadata(event, policy::SyntaxPolicy)
    !policy.allow_anchors && event.anchor !== nothing && _disallowed_syntax(:anchor, event)
    !policy.allow_tags && event.tag !== nothing && _disallowed_syntax(:tag, event)
    return nothing
end

function _complete_syntax_node!(stack::Vector{_SyntaxCollectionState})
    isempty(stack) && return nothing
    parent = stack[end]
    parent isa _SyntaxMappingState && (parent.expecting_key = !parent.expecting_key)
    return nothing
end

function _is_merge_key(event::ScalarEvent)
    return event.tag == "tag:yaml.org,2002:merge" ||
           (event.tag === nothing && event.style === nothing && event.value == "<<")
end

function _validate_mapping_key!(mapping::_SyntaxMappingState, event::ScalarEvent,
                                policy::SyntaxPolicy)
    !policy.allow_merge_keys &&
        _is_merge_key(event) &&
        _disallowed_syntax(:merge_key, event)

    keys = mapping.keys
    keys === nothing && return nothing
    first_mark = get(keys, event.value, nothing)
    first_mark === nothing ||
        throw(DuplicateKeyError(event.value, event.start_mark, first_mark))
    keys[event.value] = event.start_mark
    return nothing
end

function _invalid_event_stream(message)
    throw(ArgumentError("invalid YAML event stream: $message"))
end

function _end_mapping!(stack::Vector{_SyntaxCollectionState})
    isempty(stack) && _invalid_event_stream("mapping end without mapping start")
    mapping = pop!(stack)
    mapping isa _SyntaxMappingState ||
        _invalid_event_stream("mapping end does not match the open collection")
    mapping.expecting_key || _invalid_event_stream("mapping ended without a value")
    _complete_syntax_node!(stack)
    return nothing
end

function _end_sequence!(stack::Vector{_SyntaxCollectionState})
    isempty(stack) && _invalid_event_stream("sequence end without sequence start")
    pop!(stack) isa _SyntaxSequenceState ||
        _invalid_event_stream("sequence end does not match the open collection")
    _complete_syntax_node!(stack)
    return nothing
end

"""
    validate_events(events; policy=SyntaxPolicy()) -> SyntaxValidationSummary

Consume an iterable of YAML [`Event`](@ref) objects once and validate it against
`policy`, without constructing YAML values or retaining the complete stream.

Duplicate-key validation compares the decoded `value` of direct scalar mapping
keys. It does not resolve YAML scalar types and does not compare collection keys.
Parser and scanner exceptions from the underlying iterator propagate unchanged.
Policy failures throw a subtype of [`SyntaxPolicyError`](@ref).
"""
function validate_events(events; policy::SyntaxPolicy = SyntaxPolicy())
    stack = _SyntaxCollectionState[]
    document_count = 0
    excess_document_mark = nothing
    stream_end_mark = nothing

    for event in events
        event isa Event || _invalid_event_stream("expected Event, found $(typeof(event))")

        if event isa DocumentStartEvent
            isempty(stack) || _invalid_event_stream("document started inside a collection")
            document_count += 1
            if policy.document_count !== nothing &&
               excess_document_mark === nothing &&
               document_count > policy.document_count
                excess_document_mark = event.start_mark
            end
            !policy.allow_tags &&
                event.tags !== nothing &&
                !isempty(event.tags) &&
                _disallowed_syntax(:tag_directive, event)
        elseif event isa UnknownDirectiveEvent
            policy.allow_unknown_directives || _disallowed_syntax(:unknown_directive, event)
        elseif event isa ScalarEvent
            _validate_node_metadata(event, policy)
            if !isempty(stack)
                parent = stack[end]
                parent isa _SyntaxMappingState &&
                    parent.expecting_key &&
                    _validate_mapping_key!(parent, event, policy)
            end
            _complete_syntax_node!(stack)
        elseif event isa AliasEvent
            policy.allow_aliases || _disallowed_syntax(:alias, event)
            _complete_syntax_node!(stack)
        elseif event isa MappingStartEvent
            _validate_node_metadata(event, policy)
            !policy.allow_flow_collections &&
                event.flow_style &&
                _disallowed_syntax(:flow_mapping, event)
            keys = policy.allow_duplicate_keys ? nothing : Dict{String, Mark}()
            push!(stack, _SyntaxMappingState(true, keys))
        elseif event isa SequenceStartEvent
            _validate_node_metadata(event, policy)
            !policy.allow_flow_collections &&
                event.flow_style &&
                _disallowed_syntax(:flow_sequence, event)
            push!(stack, _SyntaxSequenceState())
        elseif event isa MappingEndEvent
            _end_mapping!(stack)
        elseif event isa SequenceEndEvent
            _end_sequence!(stack)
        elseif event isa DocumentEndEvent
            isempty(stack) || _invalid_event_stream("document ended inside a collection")
        elseif event isa StreamEndEvent
            isempty(stack) || _invalid_event_stream("stream ended inside a collection")
            stream_end_mark = event.start_mark
        end
    end

    isempty(stack) || _invalid_event_stream("stream ended with an open collection")
    expected = policy.document_count
    if expected !== nothing && document_count != expected
        mark = document_count > expected ? excess_document_mark : stream_end_mark
        throw(DocumentCountError(expected, document_count, mark))
    end
    return SyntaxValidationSummary(document_count)
end
