@testset "Event API" begin
    source = """root:
      anchor: &base !!str plain
      alias: *base
      sequence: [flow, 'single', "double"]
      literal: |
        block
      folded: >
        folded
    """

    iterator = YAMLEvents.parse_events(source)
    @test Base.IteratorSize(typeof(iterator)) isa Base.SizeUnknown
    @test eltype(iterator) === YAMLEvents.Event
    @test parentmodule(YAMLEvents.Event) === YAMLEvents
    @test parentmodule(YAMLEvents.Mark) === YAMLEvents
    @test parentmodule(YAMLEvents.EncodingError) === YAMLEvents
    @test parentmodule(YAMLEvents.ScannerError) === YAMLEvents

    events = collect(iterator)
    @test first(events) isa YAMLEvents.StreamStartEvent
    @test last(events) isa YAMLEvents.StreamEndEvent
    @test all(event -> event isa YAMLEvents.Event, events)
    @test iterate(iterator) === nothing

    document_starts = filter(event -> event isa YAMLEvents.DocumentStartEvent, events)
    @test length(document_starts) == 1
    @test !document_starts[1].explicit

    mapping_starts = filter(event -> event isa YAMLEvents.MappingStartEvent, events)
    @test length(mapping_starts) == 2
    @test all(event -> !event.flow_style, mapping_starts)

    sequence_starts = filter(event -> event isa YAMLEvents.SequenceStartEvent, events)
    @test length(sequence_starts) == 1
    @test sequence_starts[1].flow_style

    flow_mapping_events = collect(YAMLEvents.parse_events("&properties {key: value}"))
    flow_mapping_starts = filter(event -> event isa YAMLEvents.MappingStartEvent,
                                 flow_mapping_events)
    @test length(flow_mapping_starts) == 1
    @test flow_mapping_starts[1].flow_style
    @test flow_mapping_starts[1].anchor == "properties"

    scalars = filter(event -> event isa YAMLEvents.ScalarEvent, events)
    root = first(filter(event -> event.value == "root", scalars))
    @test root.start_mark.line == 1
    @test root.start_mark.column == 0
    @test root.end_mark.line == 1
    @test root.end_mark.column == 4

    anchored = first(filter(event -> event.value == "plain", scalars))
    @test anchored.anchor == "base"
    @test anchored.tag == "tag:yaml.org,2002:str"
    @test anchored.implicit == (false, false)
    @test anchored.style === nothing

    aliases = filter(event -> event isa YAMLEvents.AliasEvent, events)
    @test length(aliases) == 1
    @test aliases[1].anchor == "base"

    scalar_styles = Dict(event.value => event.style for event in scalars)
    @test scalar_styles["flow"] === nothing
    @test scalar_styles["single"] == '\''
    @test scalar_styles["double"] == '"'
    @test scalar_styles["block\n"] == '|'
    @test scalar_styles["folded\n"] == '>'

    io_events = collect(YAMLEvents.parse_events(IOBuffer(source)))
    @test typeof.(io_events) == typeof.(events)

    stream = Base.BufferStream()
    write(stream, source)
    closewrite(stream)
    stream_events = collect(YAMLEvents.parse_events(stream))
    close(stream)
    @test [event.value for event in stream_events if event isa YAMLEvents.ScalarEvent] ==
          [event.value for event in events if event isa YAMLEvents.ScalarEvent]

    multi_document_source = "---\nfirst\n...\n---\nsecond\n...\n"
    multi_document_events = collect(YAMLEvents.parse_events(multi_document_source))
    @test count(event -> event isa YAMLEvents.StreamStartEvent, multi_document_events) == 1
    @test count(event -> event isa YAMLEvents.StreamEndEvent, multi_document_events) == 1
    @test count(event -> event isa YAMLEvents.DocumentStartEvent, multi_document_events) ==
          2
    @test count(event -> event isa YAMLEvents.DocumentEndEvent, multi_document_events) == 2
    @test all(event -> event.explicit,
              filter(event -> event isa YAMLEvents.DocumentEndEvent, multi_document_events))
    @test [event.value
           for event in multi_document_events if event isa YAMLEvents.ScalarEvent] ==
          ["first", "second"]

    repeated_end_source = "first\n... # first suffix\n... # repeated suffix\n---\nsecond\n"
    repeated_end_events = collect(YAMLEvents.parse_events(repeated_end_source))
    @test count(event -> event isa YAMLEvents.DocumentStartEvent, repeated_end_events) == 2
    @test [event.value for event in repeated_end_events if event isa YAMLEvents.ScalarEvent] ==
          ["first", "second"]

    implicit_after_end_error = try
        collect(YAMLEvents.parse_events("first\n...\nsecond\n"))
    catch exception
        exception
    end
    @test implicit_after_end_error isa YAMLEvents.ParserError
    @test (implicit_after_end_error.problem_mark.index,
           implicit_after_end_error.problem_mark.line,
           implicit_after_end_error.problem_mark.column) == (10, 3, 0)

    missing_document_start = try
        collect(YAMLEvents.parse_events("%YAML 1.1\nvalue\n"))
    catch exception
        exception
    end
    @test missing_document_start isa YAMLEvents.ParserError
    @test missing_document_start.problem ==
          "expected '<document start>', but found YAML.ScalarToken"
    @test (missing_document_start.problem_mark.index,
           missing_document_start.problem_mark.line,
           missing_document_start.problem_mark.column) == (10, 2, 0)
    @test !occursin("nothing", sprint(showerror, missing_document_start))

    syntax_as_data = collect(YAMLEvents.parse_events("value: \"!tag &anchor *alias << [ {\""))
    @test isempty(filter(event -> event isa YAMLEvents.AliasEvent, syntax_as_data))
    syntax_scalar = first(filter(event -> event isa YAMLEvents.ScalarEvent &&
                                          startswith(event.value, "!tag"), syntax_as_data))
    @test syntax_scalar.tag === nothing
    @test syntax_scalar.anchor === nothing
    @test syntax_scalar.style == '"'

    duplicate_key_events = collect(YAMLEvents.parse_events("key: first\nkey: second\n"))
    @test count(event -> event isa YAMLEvents.ScalarEvent && event.value == "key",
                duplicate_key_events) == 2

    tagged_events = collect(YAMLEvents.parse_events("value: !application data\n"))
    tagged_scalar = first(filter(event -> event isa YAMLEvents.ScalarEvent &&
                                          event.value == "data", tagged_events))
    @test tagged_scalar.tag == "!application"
    @test tagged_scalar.implicit == (false, false)

    tagged_collection_events = collect(YAMLEvents.parse_events("value: &items !application [data]\n"))
    tagged_sequence = first(filter(event -> event isa YAMLEvents.SequenceStartEvent,
                                   tagged_collection_events))
    @test tagged_sequence.anchor == "items"
    @test tagged_sequence.tag == "!application"
    @test !tagged_sequence.implicit

    directive_source = "%YAML 1.1\n%TAG !e! tag:example.com,2026:\n---\n!e!value data\n"
    directive_events = collect(YAMLEvents.parse_events(directive_source))
    directive_document = first(filter(event -> event isa YAMLEvents.DocumentStartEvent,
                                      directive_events))
    @test directive_document.version == (1, 1)
    @test directive_document.tags == Dict("!e!" => "tag:example.com,2026:")
    directive_scalar = first(filter(event -> event isa YAMLEvents.ScalarEvent,
                                    directive_events))
    @test directive_scalar.tag == "tag:example.com,2026:value"

    incompatible_version = try
        collect(YAMLEvents.parse_events("%YAML 1.2\n---\ndata\n"))
    catch exception
        exception
    end
    @test incompatible_version isa YAMLEvents.ParserError
    @test occursin("version 1.1 or earlier is required", incompatible_version.problem)

    escaped_tag_events = collect(YAMLEvents.parse_events("value: !foo%C3%A9 data\n"))
    escaped_tag_scalar = only(event
                              for event in escaped_tag_events
                              if event isa YAMLEvents.ScalarEvent && event.value == "data")
    @test escaped_tag_scalar.tag == "!fooé"
    @test (escaped_tag_scalar.start_mark.index, escaped_tag_scalar.end_mark.index) ==
          (7, 22)

    escaped_directive_source = "%TAG !e! tag:example.com,%C3%A9:\n---\n!e!x data\n"
    escaped_directive_events = collect(YAMLEvents.parse_events(escaped_directive_source))
    escaped_directive_document = only(event
                                      for event in escaped_directive_events
                                      if event isa YAMLEvents.DocumentStartEvent)
    escaped_directive_scalar = only(event
                                    for event in escaped_directive_events
                                    if event isa YAMLEvents.ScalarEvent)
    @test escaped_directive_document.tags == Dict("!e!" => "tag:example.com,é:")
    @test escaped_directive_scalar.tag == "tag:example.com,é:x"
    @test_throws YAMLEvents.ScannerError collect(YAMLEvents.parse_events("value: !foo%FF data\n"))

    @test_throws YAMLEvents.ParserError collect(YAMLEvents.parse_events("[1,,2]"))
    @test_throws YAMLEvents.ScannerError collect(YAMLEvents.parse_events("value: %"))

    scanner_error = try
        collect(YAMLEvents.parse_events("value: %"))
    catch exception
        exception
    end
    @test scanner_error isa YAMLEvents.ScannerError
    @test scanner_error.problem_mark.index == 7
    @test scanner_error.problem_mark.line == 1
    @test scanner_error.problem_mark.column == 7

    parser_error = try
        collect(YAMLEvents.parse_events("[1,,2]"))
    catch exception
        exception
    end
    @test parser_error isa YAMLEvents.ParserError
    @test parser_error.problem_mark.index == 3
    @test parser_error.problem_mark.line == 1
    @test parser_error.problem_mark.column == 3

    encoding_error = try
        YAMLEvents.parse_events(IOBuffer(UInt8[0xff]))
    catch exception
        exception
    end
    @test encoding_error isa YAMLEvents.EncodingError
    @test encoding_error.encoding == "UTF-8"
    @test encoding_error.byte_sequence == "ff"
    @test occursin("invalid UTF-8 byte sequence 0xff", sprint(showerror, encoding_error))

    malformed_inputs = ((UInt8[0x61, 0xc3], "UTF-8", "c3"),
                        (UInt8[0xff, 0xfe, 0x61, 0x00, 0x62], "UTF-16LE", "62"),
                        (UInt8[0xfe, 0xff, 0xd8, 0x00], "UTF-16BE", "d800"),
                        (UInt8[0xff, 0xfe, 0x61, 0x00, 0x00, 0xd8], "UTF-16LE", "00d8"),
                        (UInt8[0xff, 0xfe, 0x00, 0x00, 0x61, 0x00, 0x00, 0x00, 0x62],
                         "UTF-32LE", "62"),
                        (UInt8[0x00, 0x00, 0xfe, 0xff, 0x00, 0x11, 0x00, 0x00], "UTF-32BE",
                         "00110000"))
    for (bytes, encoding, byte_sequence) in malformed_inputs
        malformed_error = try
            YAMLEvents.parse_events(IOBuffer(bytes))
        catch exception
            exception
        end
        @test malformed_error isa YAMLEvents.EncodingError
        @test malformed_error.encoding == encoding
        @test malformed_error.byte_sequence == byte_sequence
    end

    malformed_string_error = try
        YAMLEvents.parse_events(String(UInt8[0xc3]))
    catch exception
        exception
    end
    @test malformed_string_error isa YAMLEvents.EncodingError
    @test malformed_string_error.encoding == "UTF-8"
    @test malformed_string_error.byte_sequence == "c3"

    oversized_version = "%YAML 999999999999999999999999999999.1\n---\na\n"
    for (prefix, problem_index) in (("", 6), ("\ufeff", 7))
        oversized_iterator = YAMLEvents.parse_events(prefix * oversized_version)
        oversized_error = try
            collect(oversized_iterator)
        catch exception
            exception
        end
        @test oversized_error isa YAMLEvents.ScannerError
        @test occursin("integer that is too large", oversized_error.problem)
        @test (oversized_error.problem_mark.index, oversized_error.problem_mark.line,
               oversized_error.problem_mark.column) == (problem_index, 1, problem_index)
    end

    windows_error = try
        collect(YAMLEvents.parse_events("root:\r\n  value: %\r\n"))
    catch exception
        exception
    end
    @test windows_error isa YAMLEvents.ScannerError
    @test windows_error.problem_mark.index == 16
    @test windows_error.problem_mark.line == 2
    @test windows_error.problem_mark.column == 9

    bom_error = try
        collect(YAMLEvents.parse_events("\ufeffvalue: %"))
    catch exception
        exception
    end
    @test bom_error isa YAMLEvents.ScannerError
    @test bom_error.problem_mark.index == 8
    @test bom_error.problem_mark.line == 1
    @test bom_error.problem_mark.column == 8

    escape_error = try
        collect(YAMLEvents.parse_events("value: \"a\\q\""))
    catch exception
        exception
    end
    @test escape_error isa YAMLEvents.ScannerError
    @test escape_error.problem_mark.index == 10
    @test escape_error.problem_mark.line == 1
    @test escape_error.problem_mark.column == 10

    windows_escape_error = try
        collect(YAMLEvents.parse_events("root:\r\n  value: \"a\\q\""))
    catch exception
        exception
    end
    @test windows_escape_error isa YAMLEvents.ScannerError
    @test windows_escape_error.problem_mark.index == 19
    @test windows_escape_error.problem_mark.line == 2
    @test windows_escape_error.problem_mark.column == 12

    for escape in ("\\uD800", "\\uDFFF", "\\U00110000", "\\UFFFFFFFF")
        invalid_unicode_error = try
            collect(YAMLEvents.parse_events("value: \"" * escape * "\""))
        catch exception
            exception
        end
        @test invalid_unicode_error isa YAMLEvents.ScannerError
        @test invalid_unicode_error.problem_mark.index == 10
        @test invalid_unicode_error.problem_mark.line == 1
        @test invalid_unicode_error.problem_mark.column == 10
    end

    unicode_escape_events = collect(YAMLEvents.parse_events("value: \"\\U0001F600\""))
    unicode_escape_scalar = only(event
                                 for event in unicode_escape_events
                                 if event isa YAMLEvents.ScalarEvent &&
        event.value != "value")
    @test unicode_escape_scalar.value == "😀"
    @test isvalid(unicode_escape_scalar.value)

    warning_source = "%FOO bar\n--- value"
    @test_logs (:warn, r"unknown directive name: \"FOO\"") begin
        collect(YAMLEvents.parse_events(warning_source))
    end
end
