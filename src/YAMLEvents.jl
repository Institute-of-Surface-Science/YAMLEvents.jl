"""
    YAMLEvents

Parse YAML input into a stream of syntactic events without constructing Julia
values. Events retain document boundaries, source positions, scalar and
collection styles, tags, anchors, and aliases.
"""
module YAMLEvents

import Base: isempty, iterate, length, peek, show
using Printf: @printf
using StringEncodings: Encoding, StringDecoder, @enc_str

export parse_events
export YAMLEventIterator
export Event, Mark
export StreamStartEvent, StreamEndEvent
export DocumentStartEvent, DocumentEndEvent
export AliasEvent, ScalarEvent
export SequenceStartEvent, SequenceEndEvent
export MappingStartEvent, MappingEndEvent
export ScannerError, ParserError

include("versions.jl")
include("queue.jl")
include("buffered_input.jl")
include("mark.jl")
include("span.jl")
include("tokens.jl")
include("scanner.jl")
include("events.jl")
include("parser.jl")
include("event_api.jl")

end # module YAMLEvents
