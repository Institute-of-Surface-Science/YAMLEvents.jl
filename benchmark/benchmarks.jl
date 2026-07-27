using BenchmarkTools
using YAMLEvents

function plain_mapping_source(entries)
    output = IOBuffer()
    for index in 1:entries
        println(output, "key_$index: value_$index")
    end
    return String(take!(output))
end

function corrected_mapping_source(entries)
    output = IOBuffer()
    for index in 1:entries
        println(output, "key_$index: !tag%20value \"escaped \\\\ path \\u03bb $index\"")
    end
    return String(take!(output))
end

const SMALL_SOURCE = "service: {name: api, enabled: true}\n"
const PLAIN_SOURCE = plain_mapping_source(1_000)
const CORRECTED_SOURCE = corrected_mapping_source(250)
const MULTI_DOCUMENT_SOURCE = """
%APPLICATION strict
---
first: "value"
...
%APPLICATION relaxed
---
second: [one, two]
...
"""

function collect_io_events(source)
    return collect(parse_events(IOBuffer(source)))
end

function validate_benchmark_sources()
    for source in (SMALL_SOURCE, PLAIN_SOURCE, CORRECTED_SOURCE, MULTI_DOCUMENT_SOURCE)
        string_events = collect(parse_events(source))
        io_events = collect_io_events(source)
        isempty(string_events) && error("benchmark source produced no events")
        length(io_events) == length(string_events) ||
            error("String and IO benchmark inputs produced different event counts")
    end
    return nothing
end

# Exercise normal marks, correction replay, and explicit-document resumption.
validate_benchmark_sources()

const SUITE = BenchmarkGroup()

SUITE["construction"]["small string"] =
    @benchmarkable parse_events($SMALL_SOURCE) samples = 1_000 seconds = 1.0
SUITE["construction"]["small IO"] =
    @benchmarkable parse_events(IOBuffer($SMALL_SOURCE)) samples = 1_000 seconds = 1.0

SUITE["collection"]["small string"] =
    @benchmarkable collect(parse_events($SMALL_SOURCE)) samples = 1_000 seconds = 1.0
SUITE["collection"]["plain string"] =
    @benchmarkable collect(parse_events($PLAIN_SOURCE)) samples = 1_000 seconds = 1.0
SUITE["collection"]["plain IO"] =
    @benchmarkable collect_io_events($PLAIN_SOURCE) samples = 1_000 seconds = 1.0
SUITE["collection"]["corrected string"] =
    @benchmarkable collect(parse_events($CORRECTED_SOURCE)) samples = 1_000 seconds = 1.0
SUITE["collection"]["corrected IO"] =
    @benchmarkable collect_io_events($CORRECTED_SOURCE) samples = 1_000 seconds = 1.0
SUITE["collection"]["multiple documents string"] =
    @benchmarkable collect(parse_events($MULTI_DOCUMENT_SOURCE)) samples = 1_000 seconds = 1.0
SUITE["collection"]["multiple documents IO"] =
    @benchmarkable collect_io_events($MULTI_DOCUMENT_SOURCE) samples = 1_000 seconds = 1.0
