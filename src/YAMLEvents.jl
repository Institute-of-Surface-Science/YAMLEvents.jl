"""
    YAMLEvents

Parse YAML input into a stream of syntactic events without constructing Julia
values. Events retain document boundaries, source positions, scalar and
collection styles, tags, anchors, and aliases.
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
export AliasEvent, ScalarEvent
export SequenceStartEvent, SequenceEndEvent
export MappingStartEvent, MappingEndEvent
export EncodingError, ScannerError, ParserError

include("mark.jl")
include("events.jl")
include("errors.jl")
include("input.jl")
include("event_api.jl")

end # module YAMLEvents
