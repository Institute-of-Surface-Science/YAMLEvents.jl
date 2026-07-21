# YAMLEvents.jl

[![CI](https://github.com/Institute-of-Surface-Science/YAMLEvents.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/Institute-of-Surface-Science/YAMLEvents.jl/actions/workflows/CI.yml)

Inspect YAML syntax as a lazy stream of parser events, without constructing
dictionaries, arrays, or resolved scalar values.

Most YAML readers immediately turn a document into dictionaries, arrays, and
scalar values. YAMLEvents.jl stops at the parser-event layer instead, preserving
information that is otherwise lost during construction:

- document boundaries and directives;
- scalar text and quoting style;
- block and flow collection styles;
- explicit tags, anchors, and aliases;
- duplicate mapping keys;
- source locations for every event.

This makes the package useful for validators, linters, format-aware tooling,
configuration checks, and source-aware diagnostics.

## Installation

YAMLEvents.jl requires Julia 1.10 or later. Install it directly from GitHub:

```julia
import Pkg
Pkg.add(url="https://github.com/Institute-of-Surface-Science/YAMLEvents.jl")
```

The parser implements YAML 1.1 syntax. A `%YAML` directive declaring a newer
version is rejected with `ParserError` rather than being parsed under
incompatible rules.

## Quick start

```julia
using YAMLEvents

events = collect(parse_events("material: {D0_m2_s: 1.0e-7}"))

scalars = [event.value for event in events if event isa ScalarEvent]
# ["material", "D0_m2_s", "1.0e-7"]

mappings = [event for event in events if event isa MappingStartEvent]
mappings[1].flow_style # false: `material: ...` is a block mapping
mappings[2].flow_style # true:  `{...}` is a flow mapping
```

The value `1.0e-7` remains scalar text. YAMLEvents.jl reports how the document
was written; it does not decide which Julia type that text represents.

`parse_events(input)` accepts an `AbstractString` or an `IO` and returns a
`YAMLEventIterator`. Events are produced lazily as the iterator advances, so
callers do not need to collect the complete event stream:

```julia
open("configuration.yaml") do io
    for event in parse_events(io)
        event isa ScalarEvent || continue
        println(event.value, " at line ", event.start_mark.line)
    end
end
```

An `IO` input is buffered when `parse_events` is called. This allows pipes and
other non-seekable streams to be used and means the input may be closed before
iteration starts. Each event iterator is forward-only and may be consumed once.

## Examples

Runnable examples are available in [`examples/`](examples):

- [`simplest.jl`](examples/simplest.jl) prints the events from a minimal mapping;
- [`compare_yaml_jl.jl`](examples/compare_yaml_jl.jl) implements the same
  syntax-aware query using YAML.jl's internal event stream and YAMLEvents.jl's
  iterator API, highlighting the simpler YAMLEvents.jl implementation.

Run either example from the repository root with, for example:

```sh
julia --project=. examples/simplest.jl
```

## Event model

Every event is a subtype of `Event` and has `start_mark` and `end_mark` fields.
The remaining fields depend on the event type:

| Event | Additional fields |
| --- | --- |
| `StreamStartEvent` | `encoding` |
| `StreamEndEvent` | — |
| `DocumentStartEvent` | `explicit`, `version`, `tags` |
| `DocumentEndEvent` | `explicit` |
| `ScalarEvent` | `anchor`, `tag`, `implicit`, `value`, `style` |
| `AliasEvent` | `anchor` |
| `SequenceStartEvent` | `anchor`, `tag`, `implicit`, `flow_style` |
| `SequenceEndEvent` | — |
| `MappingStartEvent` | `anchor`, `tag`, `implicit`, `flow_style` |
| `MappingEndEvent` | — |

For scalar events, `style` is `nothing` for plain text or one of `'\''`, `'"'`,
`'|'`, and `'>'` for single-quoted, double-quoted, literal, and folded scalars.
For collection start events, `flow_style` distinguishes `[a, b]` and `{a: b}`
from block-style collections.

### Source marks

A `Mark` describes a position between characters in the input:

- `line` is one-based;
- `column` is a zero-based character offset within the line;
- `index` is a zero-based character offset within the complete stream.

An event's `start_mark` points to the beginning of its syntax and its
`end_mark` normally points immediately after it.

## Errors

Invalid byte input raises `EncodingError` if it cannot be decoded completely
using its detected UTF encoding. This happens while `parse_events` buffers an
`IO` input. An `AbstractString` containing malformed UTF-8 also raises
`EncodingError`.

Decoded input containing characters forbidden by YAML, including raw control
characters or a misplaced byte-order mark, raises `ScannerError`. Characters
whose invalidity can be established during input validation are reported while
the iterator is created.

Other malformed decoded YAML raises only `ScannerError` when the text cannot be
tokenized or `ParserError` when valid tokens cannot form a YAML document. YAML
parsing is lazy after input validation, so either syntax exception—including one
reached before a later context-dependent character check—can be raised while
iterating. Internal failures that are not attributable to malformed source are
deliberately rethrown rather than presented as input errors:

```julia
try
    collect(parse_events("[first,,second]"))
catch error
    if error isa EncodingError || error isa ScannerError || error isa ParserError
        @warn "Invalid YAML" exception=error
    else
        rethrow()
    end
end
```

## Scope

YAMLEvents.jl deliberately does not:

- resolve scalar types such as booleans, numbers, or dates;
- expand aliases or apply merge keys;
- construct dictionaries, arrays, or custom Julia objects.

Use [YAML.jl](https://github.com/JuliaData/YAML.jl) or another construction
package when Julia values are required. YAMLEvents.jl uses the registered
YAML.jl v0.4.16 release as its parser backend and converts its output into
package-owned event, mark, and error types; no custom YAML.jl fork is required.

## License

YAMLEvents.jl is available under the [MIT License](LICENSE).
Third-party test fixture provenance and license notices are recorded in
[THIRD_PARTY_NOTICE.md](THIRD_PARTY_NOTICE.md).
