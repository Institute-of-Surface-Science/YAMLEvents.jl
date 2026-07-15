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
