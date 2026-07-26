# YAMLEvents.jl release notes

## Version 0.2.0

- Preserve unknown directives as source-aware `UnknownDirectiveEvent` objects
  without producing global log messages.
- Add `unknown_directives=:error` for consumers that reject unknown directives.

## Version 0.1.1

- Normalize overflowing YAML directive components and invalid Unicode escapes
  to source-aware `ScannerError` exceptions.
- Preserve context and problem marks for scanner conversion failures.
- Guarantee that malformed decoded YAML is reported as `ScannerError` or
  `ParserError` without converting unrelated internal failures.

## Version 0.1.0

Initial release.

- Parse YAML 1.1 into a forward-only stream of syntactic events.
- Preserve document boundaries, scalar styles, collection styles, tags,
  anchors, aliases, duplicate keys, and source marks.
- Accept strings and seekable or non-seekable `IO` inputs.
- Report encoding, scanner, and parser failures with package-owned error types.
- Support UTF-8, UTF-16, and UTF-32 input.
- Use the registered YAML.jl v0.4.16 release as the parser backend.
