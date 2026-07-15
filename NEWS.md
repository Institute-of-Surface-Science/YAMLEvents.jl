# YAMLEvents.jl release notes

## Version 0.1.0

Initial release.

- Parse YAML into a forward-only stream of syntactic events.
- Preserve document boundaries, scalar styles, collection styles, tags,
  anchors, aliases, duplicate keys, and source marks.
- Accept strings and seekable or non-seekable `IO` inputs.
- Report scanner and parser failures with source-aware error types.
- Support UTF-8, UTF-16, and UTF-32 input.
- Use the registered YAML.jl v0.4.16 release as the parser backend.
