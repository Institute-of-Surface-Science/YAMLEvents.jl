"""Abstract supertype for events returned by [`parse_events`](@ref)."""
abstract type Event end

struct StreamStartEvent <: Event
    start_mark::Mark
    end_mark::Mark
    encoding::String
end

struct StreamEndEvent <: Event
    start_mark::Mark
    end_mark::Mark
end

struct DocumentStartEvent <: Event
    start_mark::Mark
    end_mark::Mark
    explicit::Bool
    version::Union{Tuple, Nothing}
    tags::Union{Dict{String, String}, Nothing}
end

struct DocumentEndEvent <: Event
    start_mark::Mark
    end_mark::Mark
    explicit::Bool
end

struct AliasEvent <: Event
    start_mark::Mark
    end_mark::Mark
    anchor::Union{String, Nothing}
end

struct ScalarEvent <: Event
    start_mark::Mark
    end_mark::Mark
    anchor::Union{String, Nothing}
    tag::Union{String, Nothing}
    implicit::NTuple{2, Bool}
    value::String
    style::Union{Char, Nothing}
end

struct SequenceStartEvent <: Event
    start_mark::Mark
    end_mark::Mark
    anchor::Union{String, Nothing}
    tag::Union{String, Nothing}
    implicit::Bool
    flow_style::Bool
end

struct SequenceEndEvent <: Event
    start_mark::Mark
    end_mark::Mark
end

struct MappingStartEvent <: Event
    start_mark::Mark
    end_mark::Mark
    anchor::Union{String, Nothing}
    tag::Union{String, Nothing}
    implicit::Bool
    flow_style::Bool
end

struct MappingEndEvent <: Event
    start_mark::Mark
    end_mark::Mark
end
