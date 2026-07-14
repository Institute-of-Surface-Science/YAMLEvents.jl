"""
    Event

Abstract supertype for events returned by [`parse_events`](@ref).

Every concrete event has `start_mark` and `end_mark` fields describing its
location in the input stream. Collection start events contain style, tag, and
anchor information before aliases or tags are resolved by the constructor.
"""
abstract type Event end

"""Start of a YAML stream, including the detected character `encoding`."""
struct StreamStartEvent <: Event
    start_mark::Mark
    end_mark::Mark
    encoding::String
end

"""End of a YAML stream."""
struct StreamEndEvent <: Event
    start_mark::Mark
    end_mark::Mark
end

"""
Start of a YAML document.

`explicit` indicates whether the document starts with `---`. `version` and
`tags` contain values declared by directives. `version` is `nothing` when no
version directive is present. `tags` is `nothing` for an implicit document and
an empty dictionary when an explicit document has no tag directives.
"""
struct DocumentStartEvent <: Event
    start_mark::Mark
    end_mark::Mark
    explicit::Bool
    version::Union{Tuple, Nothing}
    tags::Union{Dict{String, String}, Nothing}

    function DocumentStartEvent(start_mark::Mark, end_mark::Mark, explicit::Bool,
                                version = nothing, tags = nothing)
        new(start_mark, end_mark, explicit, version, tags)
    end
end

"""
End of a YAML document.

`explicit` indicates whether the document ends with `...`.
"""
struct DocumentEndEvent <: Event
    start_mark::Mark
    end_mark::Mark
    explicit::Bool
end

"""An alias referring to `anchor`."""
struct AliasEvent <: Event
    start_mark::Mark
    end_mark::Mark
    anchor::Union{String, Nothing}
end

"""
A scalar value before YAML type construction.

`value` is the decoded scalar text and `style` is `nothing` for a plain scalar,
or one of `'\''`, `'"'`, `'|'`, or `'>'`. `tag` is `nothing` when no explicit
tag was supplied and otherwise contains the expanded tag. `anchor` contains
the anchor name when present.

`implicit` is `(plain, nonplain)`, indicating whether the tag may be resolved
implicitly for plain and non-plain scalar styles respectively.
"""
struct ScalarEvent <: Event
    start_mark::Mark
    end_mark::Mark
    anchor::Union{String, Nothing}
    tag::Union{String, Nothing}
    implicit::NTuple{2, Bool}
    value::String
    style::Union{Char, Nothing}
end

"""
Start of a sequence.

`flow_style` is `true` for `[a, b]` and `false` for a block sequence. `tag`,
`anchor`, and `implicit` describe tag and anchor syntax attached to the
collection.
"""
struct SequenceStartEvent <: Event
    start_mark::Mark
    end_mark::Mark
    anchor::Union{String, Nothing}
    tag::Union{String, Nothing}
    implicit::Bool
    flow_style::Bool
end

"""End of a sequence."""
struct SequenceEndEvent <: Event
    start_mark::Mark
    end_mark::Mark
end

"""
Start of a mapping.

`flow_style` is `true` for `{a: b}` and `false` for a block mapping. `tag`,
`anchor`, and `implicit` describe tag and anchor syntax attached to the
collection.
"""
struct MappingStartEvent <: Event
    start_mark::Mark
    end_mark::Mark
    anchor::Union{String, Nothing}
    tag::Union{String, Nothing}
    implicit::Bool
    flow_style::Bool
end

"""End of a mapping."""
struct MappingEndEvent <: Event
    start_mark::Mark
    end_mark::Mark
end
