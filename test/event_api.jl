function captured_parse_error(input)
    try
        collect(YAMLEvents.parse_events(input))
        return nothing
    catch exception
        return exception
    end
end

mark_coordinates(mark) = (mark.index, mark.line, mark.column)

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
    @test parentmodule(YAMLEvents.UnknownDirectiveEvent) === YAMLEvents
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

    oversized_component = string(BigInt(typemax(Int)) + 1)
    oversized_versions = (("%YAML $oversized_component.1\n---\na\n", (0, 1, 0), (6, 1, 6)),
                          ("%YAML 1.$oversized_component\n---\na\n", (0, 1, 0), (8, 1, 8)),
                          ("\ufeff%YAML $oversized_component.1\n---\na\n", (1, 1, 1),
                           (7, 1, 7)),
                          ("first\r\n...\r\n%YAML $oversized_component.1\r\n---\r\nsecond\r\n",
                           (12, 3, 0), (18, 3, 6)))
    for (source, context_mark, problem_mark) in oversized_versions
        oversized_iterator = YAMLEvents.parse_events(source)
        oversized_error = captured_parse_error(source)
        @test oversized_error isa YAMLEvents.ScannerError
        @test oversized_error.context == "while scanning a directive"
        @test mark_coordinates(oversized_error.context_mark) == context_mark
        @test occursin("integer that is too large", oversized_error.problem)
        @test mark_coordinates(oversized_error.problem_mark) == problem_mark
        @test iterate(oversized_iterator) !== nothing
    end

    io_overflow = captured_parse_error(IOBuffer("%YAML 1.$oversized_component\n---\na\n"))
    @test io_overflow isa YAMLEvents.ScannerError
    @test mark_coordinates(io_overflow.context_mark) == (0, 1, 0)
    @test mark_coordinates(io_overflow.problem_mark) == (8, 1, 8)

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

    for (escape,
         codepoint) in (("\\uD800", "U+D800"), ("\\uDFFF", "U+DFFF"),
                        ("\\U0000D800", "U+D800"), ("\\U00110000", "U+00110000"),
                        ("\\UFFFFFFFF", "U+FFFFFFFF"))
        invalid_unicode_error = captured_parse_error("value: \"" * escape * "\"")
        @test invalid_unicode_error isa YAMLEvents.ScannerError
        @test invalid_unicode_error.context == "while scanning a double-quoted scalar"
        @test mark_coordinates(invalid_unicode_error.context_mark) == (7, 1, 7)
        @test occursin(codepoint, invalid_unicode_error.problem)
        @test mark_coordinates(invalid_unicode_error.problem_mark) == (10, 1, 10)
    end

    corrected_unicode_source = "root: é\r\nvalue: \"\\UFFFFFFFF\"\r\n"
    corrected_unicode_error = captured_parse_error(IOBuffer(corrected_unicode_source))
    @test corrected_unicode_error isa YAMLEvents.ScannerError
    @test mark_coordinates(corrected_unicode_error.context_mark) == (16, 2, 7)
    @test mark_coordinates(corrected_unicode_error.problem_mark) == (19, 2, 10)

    escaped_quote_error = captured_parse_error("value: \"a\\\"b\\uD800\"\n")
    @test escaped_quote_error isa YAMLEvents.ScannerError
    @test mark_coordinates(escaped_quote_error.context_mark) == (7, 1, 7)
    @test mark_coordinates(escaped_quote_error.problem_mark) == (14, 1, 14)

    valid_unicode_escapes = (("\\uD7FF", Char(0xd7ff)), ("\\uE000", Char(0xe000)),
                             ("\\U0001F600", '😀'), ("\\U0010FFFF", Char(0x10ffff)))
    for (escape, expected) in valid_unicode_escapes
        unicode_escape_events = collect(YAMLEvents.parse_events("value: \"$escape\""))
        unicode_escape_scalar = only(event
                                     for event in unicode_escape_events
                                     if event isa YAMLEvents.ScalarEvent &&
                                        event.value != "value")
        @test unicode_escape_scalar.value == string(expected)
        @test isvalid(unicode_escape_scalar.value)
    end

    conversion_audit_sources = ("%YAML .1\n---\na\n", "value: |0\n text\n",
                                "value: !foo%G0 data\n", "value: \"\\U0000ZZZZ\"\n")
    for source in conversion_audit_sources
        error = captured_parse_error(source)
        @test error isa Union{YAMLEvents.ScannerError, YAMLEvents.ParserError}
    end

    block_scalar_events = collect(YAMLEvents.parse_events("value: |1\n text\n"))
    @test any(event -> event isa YAMLEvents.ScalarEvent && event.value == "text\n",
              block_scalar_events)

    simulated_32_bit_state = YAMLEvents.parse_events("value: \"\\UFFFFFFFF\"\n")._state
    simulated_32_bit_error = YAMLEvents._unicode_escape_error(simulated_32_bit_state,
                                                              OverflowError("32-bit"),
                                                              UInt64(10), typemax(Int32))
    @test simulated_32_bit_error isa YAMLEvents.ScannerError
    @test occursin("U+FFFFFFFF", simulated_32_bit_error.problem)
    @test YAMLEvents._unicode_escape_error(simulated_32_bit_state,
                                           OverflowError("unrelated"), UInt64(10),
                                           typemax(Int64)) === nothing

    unrelated_iterator = YAMLEvents.parse_events("%YAML $oversized_component.1\n---\na\n")
    for _ in 1:6
        YAMLEvents.YAML.forward!(unrelated_iterator._state.tokenstream.input)
    end
    unrelated_error = try
        YAMLEvents._with_error_conversion(unrelated_iterator._state) do
            throw(OverflowError("sentinel"))
        end
    catch exception
        exception
    end
    @test unrelated_error isa OverflowError
    @test unrelated_error.msg == "sentinel"

    @testset "Unknown directives" begin
        directive_source = "%FOO café # note\r\n---\r\nvalue\r\n"
        directive_events = @test_logs min_level = Logging.Warn begin
            collect(YAMLEvents.parse_events(directive_source))
        end
        directive = only(event
                         for event in directive_events
                         if event isa YAMLEvents.UnknownDirectiveEvent)
        @test directive.name == "FOO"
        @test directive.content == " café # note"
        @test mark_coordinates(directive.start_mark) == (0, 1, 0)
        directive_length = length("%FOO café # note")
        @test mark_coordinates(directive.end_mark) ==
              (directive_length, 1, directive_length)
        @test typeof.(directive_events[1:3]) ==
              [YAMLEvents.StreamStartEvent, YAMLEvents.UnknownDirectiveEvent,
               YAMLEvents.DocumentStartEvent]
        value = only(event
                     for event in directive_events
                     if event isa YAMLEvents.ScalarEvent && event.value == "value")
        @test mark_coordinates(value.start_mark) == (23, 3, 0)

        encoded_source = "%ENCODED café\n---\nvalue\n"
        for encoding in ("UTF-16LE", "UTF-32BE")
            encoded_events = collect(YAMLEvents.parse_events(IOBuffer(encode(encoded_source,
                                                                              encoding))))
            encoded_directive = only(event
                                     for event in encoded_events
                                     if event isa YAMLEvents.UnknownDirectiveEvent)
            @test encoded_directive.name == "ENCODED"
            @test encoded_directive.content == " café"
            @test mark_coordinates(encoded_directive.start_mark) == (0, 1, 0)
            @test mark_coordinates(encoded_directive.end_mark) == (13, 1, 13)
        end

        empty_directive = only(event
                               for event in YAMLEvents.parse_events("%EMPTY\n---\nvalue\n")
                               if event isa YAMLEvents.UnknownDirectiveEvent)
        @test empty_directive.name == "EMPTY"
        @test isempty(empty_directive.content)
        @test mark_coordinates(empty_directive.end_mark) == (6, 1, 6)

        mixed_source = "%FOO first\n%YAML 1.1\n%BAR second  \n---\nvalue\n"
        mixed_events = collect(YAMLEvents.parse_events(mixed_source))
        mixed_directives = [event
                            for event in mixed_events
                            if event isa YAMLEvents.UnknownDirectiveEvent]
        @test getproperty.(mixed_directives, :name) == ["FOO", "BAR"]
        @test getproperty.(mixed_directives, :content) == [" first", " second  "]
        mixed_document = only(event
                              for event in mixed_events
                              if event isa YAMLEvents.DocumentStartEvent)
        @test mixed_document.version == (1, 1)

        known_source = "%YAML 1.1\n%TAG !e! tag:example.com,2026:\n---\n!e!item value\n"
        known_events = collect(YAMLEvents.parse_events(known_source;
                                                       unknown_directives = :error))
        @test !any(event -> event isa YAMLEvents.UnknownDirectiveEvent, known_events)
        known_document = only(event
                              for event in known_events
                              if event isa YAMLEvents.DocumentStartEvent)
        @test known_document.version == (1, 1)
        @test known_document.tags == Dict("!e!" => "tag:example.com,2026:")

        between_source = "first\n...\n%LATER next\n---\nsecond\n"
        between_events = @test_logs min_level = Logging.Warn begin
            collect(YAMLEvents.parse_events(between_source))
        end
        later_index = findfirst(event -> event isa YAMLEvents.UnknownDirectiveEvent,
                                between_events)
        preceding_end = findprev(event -> event isa YAMLEvents.DocumentEndEvent,
                                 between_events, later_index)
        following_start = findnext(event -> event isa YAMLEvents.DocumentStartEvent,
                                   between_events, later_index)
        @test preceding_end < later_index < following_start
        @test between_events[later_index].name == "LATER"

        missing_start_iterator = YAMLEvents.parse_events("%FOO data\nvalue\n")
        @test first(iterate(missing_start_iterator)) isa YAMLEvents.StreamStartEvent
        @test first(iterate(missing_start_iterator)) isa YAMLEvents.UnknownDirectiveEvent
        @test_throws YAMLEvents.ParserError iterate(missing_start_iterator)

        strict_source = "%STRICT rejected\n---\nvalue\n"
        strict_error = @test_logs min_level = Logging.Warn begin
            try
                collect(YAMLEvents.parse_events(strict_source;
                                                unknown_directives = :error))
                nothing
            catch exception
                exception
            end
        end
        @test strict_error isa YAMLEvents.ScannerError
        @test strict_error.context == "while scanning a directive"
        @test strict_error.problem == "found unknown directive \"STRICT\""
        @test mark_coordinates(strict_error.context_mark) == (0, 1, 0)
        @test mark_coordinates(strict_error.problem_mark) == (0, 1, 0)

        lazy_strict = YAMLEvents.parse_events(between_source;
                                              unknown_directives = :error)
        while true
            event = first(iterate(lazy_strict))
            event isa YAMLEvents.DocumentEndEvent && event.explicit && break
        end
        @test_throws YAMLEvents.ScannerError iterate(lazy_strict)

        @test_logs (:warn, "unrelated warning") begin
            collect(YAMLEvents.parse_events("%FOO data\n---\nvalue\n"))
            @warn "unrelated warning"
        end

        @test_throws ArgumentError YAMLEvents.parse_events("value\n";
                                                           unknown_directives = :ignore)
        @test_throws ArgumentError YAMLEvents.parse_events(IOBuffer("value\n");
                                                           unknown_directives = false)
    end
end
