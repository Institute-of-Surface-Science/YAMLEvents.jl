const YAML_CORPUS = (["spec-02-$(lpad(index, 2, '0'))" for index in 1:23]...,
                     "empty_scalar", "no_trailing_newline", "windows_newlines",
                     "escape_sequences", "issue15", "issue30", "issue36", "issue39",
                     "issue132", "cartesian", "ar1", "ar1_cartesian", "merge-01",
                     "version-colon", "multi-constructor", "utf-8-bom", "utf-32-be",
                     "empty_tag", "empty_list_elem", "empty_key", "nested_empty_array",
                     "keys_need_quoting")

@testset "Parser corpus" begin
    for name in YAML_CORPUS
        @testset "$name" begin
            path = joinpath(@__DIR__, "yaml", "$name.yaml")
            events = collect(parse_events(IOBuffer(read(path))))

            @test first(events) isa StreamStartEvent
            @test last(events) isa StreamEndEvent
            @test count(event -> event isa DocumentStartEvent, events) >= 1
            @test count(event -> event isa DocumentStartEvent, events) ==
                  count(event -> event isa DocumentEndEvent, events)
        end
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
