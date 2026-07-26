"""
    YAMLEvents

Parse YAML input into a stream of syntactic events without constructing Julia
values. Events retain document boundaries, source positions, scalar and
collection styles, directives, tags, anchors, and aliases.
"""
module YAMLEvents

import Logging
import StringEncodings
import YAML

export parse_events
export YAMLEventIterator
export Event, Mark
export StreamStartEvent, StreamEndEvent
export DocumentStartEvent, DocumentEndEvent
export UnknownDirectiveEvent
export AliasEvent, ScalarEvent
export SequenceStartEvent, SequenceEndEvent
export MappingStartEvent, MappingEndEvent
export EncodingError, ScannerError, ParserError

include("mark.jl")
include("events.jl")
include("errors.jl")
include("input.jl")
include("mark_conversion.jl")
include("source_validation.jl")
include("event_conversion.jl")
include("event_api.jl")

end # module YAMLEvents
