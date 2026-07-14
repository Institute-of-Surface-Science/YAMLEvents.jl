# YAMLEvents.jl

[![CI](https://github.com/Institute-of-Surface-Science/YAMLEvents.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/Institute-of-Surface-Science/YAMLEvents.jl/actions/workflows/CI.yml)

YAMLEvents.jl parses YAML input into a forward-only stream of syntactic events
without constructing Julia values. It preserves the syntax information needed
by validators, linters, configuration tools, and source-aware diagnostics:

- document boundaries;
- scalar text and style;
- block and flow collection style;
- explicit tags, anchors, and aliases;
- source marks for every event.

The parser frontend is derived from
[YAML.jl](https://github.com/JuliaData/YAML.jl). YAMLEvents.jl owns its event
types and does not modify or depend on the YAML.jl namespace.

## Usage

```julia
using YAMLEvents

events = collect(parse_events("material: {D0_m2_s: 1.0e-7}"))

for event in events
    if event isa ScalarEvent
        println(event.value, " at ", event.start_mark)
    end
end
```

`parse_events` accepts an `AbstractString` or `IO`. The returned iterator is
forward-only and may be consumed once. Malformed input throws `ScannerError` or
`ParserError`.

## Scope

YAMLEvents.jl reports YAML syntax. It deliberately does not resolve scalar
types, expand aliases, apply merge keys, or construct dictionaries and arrays.
Use a YAML construction package after syntax validation when Julia values are
required.

## Provenance

The scanner and parser frontend was extracted from the Institute of Surface
Science YAML.jl fork at
[`232fe77`](https://github.com/Institute-of-Surface-Science/YAML.jl/commit/232fe771bbe19d34a9d55ccda53f3e6143624808).
See
[`THIRD_PARTY_NOTICE.md`](THIRD_PARTY_NOTICE.md) for attribution and licensing.
