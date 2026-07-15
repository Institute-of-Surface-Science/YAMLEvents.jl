const YAML_CORPUS = (["spec-02-$(lpad(index, 2, '0'))" for index in 1:23]...,
                     "empty_scalar", "no_trailing_newline", "windows_newlines",
                     "escape_sequences", "issue15", "issue30", "issue36", "issue39",
                     "issue132", "cartesian", "ar1", "ar1_cartesian", "merge-01",
                     "version-colon", "multi-constructor", "utf-8-bom", "utf-32-be",
                     "empty_tag", "empty_list_elem", "empty_key", "nested_empty_array",
                     "keys_need_quoting")

function well_formed_event_stream(events)
    isempty(events) && return false
    first(events) isa StreamStartEvent || return false
    last(events) isa StreamEndEvent || return false
    count(event -> event isa StreamStartEvent, events) == 1 || return false
    count(event -> event isa StreamEndEvent, events) == 1 || return false

    documents = 0
    collections = DataType[]
    for event in events
        if event isa DocumentStartEvent
            isempty(collections) || return false
            documents += 1
        elseif event isa SequenceStartEvent
            push!(collections, SequenceStartEvent)
        elseif event isa MappingStartEvent
            push!(collections, MappingStartEvent)
        elseif event isa SequenceEndEvent
            isempty(collections) && return false
            pop!(collections) === SequenceStartEvent || return false
        elseif event isa MappingEndEvent
            isempty(collections) && return false
            pop!(collections) === MappingStartEvent || return false
        elseif event isa DocumentEndEvent
            isempty(collections) || return false
            documents -= 1
            documents >= 0 || return false
        end
    end

    return documents == 0 && isempty(collections)
end

@testset "Parser smoke corpus" begin
    for name in YAML_CORPUS
        @testset "$name" begin
            path = joinpath(@__DIR__, "yaml", "$name.yaml")
            events = collect(parse_events(IOBuffer(read(path))))
            @test well_formed_event_stream(events)
        end
    end
end

function scalar_values(path)
    events = collect(parse_events(IOBuffer(read(path))))
    return [event.value for event in events if event isa ScalarEvent]
end

@testset "Corpus event expectations" begin
    directory = joinpath(@__DIR__, "yaml")
    @test scalar_values(joinpath(directory, "no_trailing_newline.yaml")) == ["hello", ""]
    @test scalar_values(joinpath(directory, "utf-32-be.yaml")) == ["attribute", "1"]

    nested_events = collect(parse_events(IOBuffer(read(joinpath(directory,
                                                                "nested_empty_array.yaml")))))
    @test typeof.(nested_events) == [
        StreamStartEvent,
        DocumentStartEvent,
        SequenceStartEvent,
        SequenceStartEvent,
        SequenceEndEvent,
        SequenceEndEvent,
        DocumentEndEvent,
        StreamEndEvent
    ]

    utf32_events = collect(parse_events(IOBuffer(read(joinpath(directory, "utf-32-be.yaml")))))
    @test first(utf32_events).encoding == "UTF-32BE"
    attribute = only(event
                     for event in utf32_events
                     if event isa ScalarEvent && event.value == "attribute")
    @test (attribute.start_mark.index, attribute.start_mark.line,
           attribute.start_mark.column) == (4, 2, 0)

    bom_events = collect(parse_events(IOBuffer(read(joinpath(directory, "utf-8-bom.yaml")))))
    @test first(bom_events).encoding == "UTF-8"
    bom_attribute = only(event
                         for event in bom_events
                         if event isa ScalarEvent && event.value == "attribute")
    @test (bom_attribute.start_mark.index, bom_attribute.start_mark.line,
           bom_attribute.start_mark.column) == (6, 2, 0)

    multi_bom_source = "\ufeff---\nfirst\n...\n\ufeff---\nsecond\n"
    multi_bom_events = collect(parse_events(multi_bom_source))
    document_starts = filter(event -> event isa DocumentStartEvent, multi_bom_events)
    @test [(event.start_mark.index, event.start_mark.line, event.start_mark.column)
           for event in document_starts] == [(1, 1, 1), (16, 4, 1)]
    second = only(event
                  for event in multi_bom_events
                  if event isa ScalarEvent && event.value == "second")
    @test (second.start_mark.index, second.start_mark.line, second.start_mark.column) ==
          (20, 5, 0)

    quoted_bom = only(event
                      for event in parse_events("%YAML 1.1\n---\nfirst: \"a\ufeffb\"\n")
                      if event isa ScalarEvent && event.value != "first")
    @test quoted_bom.value == "a\ufeffb"

    multiline_quoted_bom = only(event
                                for event in parse_events("first: \"a\n\ufeffb\"\n")
                                if event isa ScalarEvent && event.value != "first")
    @test multiline_quoted_bom.value == "a\n\ufeffb"

    mapping_bom_error = try
        parse_events("a: 1\n\ufeffb: 2\n")
    catch exception
        exception
    end
    @test mapping_bom_error isa ScannerError
    @test (mapping_bom_error.problem_mark.index, mapping_bom_error.problem_mark.line,
           mapping_bom_error.problem_mark.column) == (5, 2, 0)
end

@testset "Input encodings" begin
    source = "---\r\nattribute: 1\r\n"
    for encoding in ("UTF-8", "UTF-16BE", "UTF-16LE", "UTF-32BE", "UTF-32LE")
        events = collect(parse_events(IOBuffer(encode(source, encoding))))
        @test first(events).encoding == encoding
        attribute = only(event
                         for event in events
                         if event isa ScalarEvent && event.value == "attribute")
        @test (attribute.start_mark.index, attribute.start_mark.line,
               attribute.start_mark.column) == (5, 2, 0)
    end

    unicode_source = "---\nvalue: 😀\n"
    for encoding in ("UTF-8", "UTF-16BE", "UTF-16LE", "UTF-32BE", "UTF-32LE")
        values = [event.value
                  for event in parse_events(IOBuffer(encode(unicode_source, encoding)))
                  if event isa ScalarEvent]
        @test values == ["value", "😀"]
    end
end

@testset "YAML character set" begin
    for codepoint in (0x00, 0x01, 0x07, 0x08, 0x0b, 0x0c, 0x7f, 0x80, 0x9f, 0xfffe, 0xffff)
        source = "value: a" * string(Char(codepoint)) * "b\nnext: value\n"
        error = try
            parse_events(source)
        catch exception
            exception
        end
        @test error isa ScannerError
        @test error.problem_mark.index == 8
        @test occursin("U+", error.problem)
    end

    for codepoint in (0x7f, 0x80, 0x9f, 0xfeff, 0xfffe, 0xffff)
        value = "a" * string(Char(codepoint)) * "b"
        quoted = only(event
                      for event in parse_events("%YAML 1.1\n---\nvalue: \"$value\"\n")
                      if event isa ScalarEvent && event.value != "value")
        @test quoted.value == value
    end

    single_quoted_c1 = only(event
                            for event in parse_events("value: 'a\u0080b'\n")
                            if event isa ScalarEvent && event.value != "value")
    @test single_quoted_c1.value == "a\u0080b"
    @test_throws ScannerError parse_events("value: \"a\u0001b\"\n")
    invalid_context_sources = ("value: &a\u0080b data\n", "value: !a\u0080b data\n",
                               "value: &a\ufeffb data\n", "value: !a\ufeffb data\n")
    for source in invalid_context_sources
        @test_throws ScannerError parse_events(source)
    end

    crlf_error = try
        parse_events("root:\r\n" * string(Char(0x01)))
    catch exception
        exception
    end
    @test crlf_error isa ScannerError
    @test (crlf_error.problem_mark.index, crlf_error.problem_mark.line,
           crlf_error.problem_mark.column) == (7, 2, 0)

    escaped_null = only(event
                        for event in parse_events("value: \"\\0\"\n")
                        if event isa ScalarEvent && event.value != "value")
    @test escaped_null.value == "\0"
end

@testset "Event source marks" begin
    events = collect(parse_events("root:\n  value: data\n"))
    value = only(event
                 for event in events if event isa ScalarEvent && event.value == "data")

    @test value.start_mark.line == 2
    @test value.start_mark.column == 9
    @test value.start_mark.index == 15
    @test value.end_mark.line == 2
    @test value.end_mark.column == 13
    @test value.end_mark.index == 19
end

@testset "Scanner source mark corrections" begin
    quoted_cases = (("first: \"can't\"\nnext: value\n", 14, 15),
                    ("first: \"a\\nb\"\nnext: value\n", 13, 14),
                    ("first: \"a\\u0041b\"\nnext: value\n", 17, 18),
                    ("first: 'a\\b'\nnext: value\n", 12, 13),
                    ("first: \"a\n    b\"\nnext: value\n", 16, 17),
                    ("first: \"a\\\n    b\"\nnext: value\n", 17, 18))
    for (source, quoted_end, next_start) in quoted_cases
        events = collect(parse_events(source))
        quoted = only(event
                      for event in events
                      if event isa ScalarEvent && event.start_mark.index == 7)
        next_scalar = only(event
                           for event in events
                           if event isa ScalarEvent && event.value == "next")
        @test quoted.end_mark.index == quoted_end
        @test next_scalar.start_mark.index == next_start
        @test next_scalar.start_mark.column == 0
    end

    flow_source = "{first: \"can't\", next: value}"
    flow_next = only(event
                     for event in parse_events(flow_source)
                     if event isa ScalarEvent && event.value == "next")
    @test (flow_next.start_mark.index, flow_next.start_mark.line,
           flow_next.start_mark.column) == (17, 1, 17)

    tag_source = "first: !foo%20bar value\nnext: value\n"
    tag_events = collect(parse_events(tag_source))
    tagged_value = only(event
                        for event in tag_events
                        if event isa ScalarEvent &&
                               event.value == "value" &&
                               event.start_mark.line == 1)
    tag_next = only(event
                    for event in tag_events
                    if event isa ScalarEvent && event.value == "next")
    @test (tagged_value.start_mark.index, tagged_value.end_mark.index) == (7, 23)
    @test (tag_next.start_mark.index, tag_next.start_mark.column) == (24, 0)

    directive_source = "%TAG !e! tag:example.com,2026:%20\n---\n" *
                       "first: !e!value data\nnext: value\n"
    directive_next = only(event
                          for event in parse_events(directive_source)
                          if event isa ScalarEvent && event.value == "next")
    @test (directive_next.start_mark.index, directive_next.start_mark.line,
           directive_next.start_mark.column) == (59, 4, 0)

    combined_source = "\ufefffirst: \"can't\"\n...\n\ufeff---\nnext: value\n"
    combined_next = only(event
                         for event in parse_events(combined_source)
                         if event isa ScalarEvent && event.value == "next")
    @test (combined_next.start_mark.index, combined_next.start_mark.line,
           combined_next.start_mark.column) == (25, 4, 0)
end

@testset "Line break source marks" begin
    for (line_break, start_index) in (("\n", 15), ("\r", 15), ("\r\n", 16))
        source = "root:" * line_break * "  value: data" * line_break
        value = only(event
                     for event in parse_events(source)
                     if event isa ScalarEvent && event.value == "data")
        @test (value.start_mark.index, value.start_mark.line, value.start_mark.column) ==
              (start_index, 2, 9)
        @test (value.end_mark.index, value.end_mark.line, value.end_mark.column) ==
              (start_index + 4, 2, 13)
    end
end

@testset "Sparse source index mapping" begin
    plain_source = repeat("key: value\n", 10_000)
    plain_input = YAMLEvents._prepare_input(plain_source)
    @test plain_input.source === plain_source
    @test isempty(plain_input.newline_corrections)
    @test plain_input.character_count == length(plain_source)

    leading_bom_input = YAMLEvents._prepare_input("\ufeff" * plain_source)
    @test isempty(YAMLEvents._context_characters(leading_bom_input))

    windows_input = YAMLEvents._prepare_input("a\r\nb\r\n")
    @test windows_input.source == "a\nb\n"
    @test windows_input.newline_corrections == UInt64[2, 4]
    @test windows_input.character_count == 4

    correction_iterator = parse_events(repeat("- \"can't\"\n", 100))
    collect(correction_iterator)
    converter = correction_iterator._state.mark_converter
    @test length(converter.skipped_indices) == 100
    @test converter.line_start_positions == collect(UInt64(0):UInt64(10):UInt64(1000))
end
