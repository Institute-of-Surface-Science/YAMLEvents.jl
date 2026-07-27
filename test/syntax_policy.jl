function captured_policy_error(source; policy = SyntaxPolicy(), unknown_directives = :event)
    try
        validate_events(parse_events(source; unknown_directives); policy)
        return nothing
    catch exception
        return exception
    end
end

struct StopAfterEvents
    events::Vector{Event}
    limit::Int
end

function Base.iterate(iterator::StopAfterEvents, index::Int = 1)
    index > iterator.limit && error("event iterator consumed past policy failure")
    return iterator.events[index], index + 1
end

@testset "Syntax policy" begin
    @testset "Policy and summary" begin
        policy = SyntaxPolicy()
        @test policy.document_count === nothing
        @test policy.allow_flow_collections
        @test policy.allow_anchors
        @test policy.allow_aliases
        @test policy.allow_tags
        @test policy.allow_unknown_directives
        @test policy.allow_merge_keys
        @test policy.allow_duplicate_keys
        @test_throws ArgumentError SyntaxPolicy(document_count = -1)

        permissive_source = """
        %APPLICATION strict
        %TAG !e! tag:example.com,2026:
        ---
        base: &base {tagged: !e!value data}
        copy: *base
        merged: {<<: *base}
        """
        summary = validate_events(parse_events(permissive_source))
        @test summary isa SyntaxValidationSummary
        @test summary.document_count == 1

        iterator = parse_events("---\nfirst\n---\nsecond\n")
        generated_events = (event for event in iterator)
        @test validate_events(generated_events).document_count == 2
        @test iterate(iterator) === nothing
        @test validate_events(parse_events("")).document_count == 0
    end

    @testset "Document count" begin
        policy = SyntaxPolicy(document_count = 1)
        @test validate_events(parse_events("value\n"); policy).document_count == 1

        missing = captured_policy_error(""; policy)
        @test missing isa DocumentCountError
        @test missing isa SyntaxPolicyError
        @test missing.expected == 1
        @test missing.actual == 0
        @test mark_coordinates(missing.mark) == (0, 1, 0)
        @test occursin("expected 1 YAML document, found 0 documents",
                       sprint(showerror, missing))

        multiple_source = "---\nfirst\n---\nsecond\n---\nthird\n"
        multiple = captured_policy_error(multiple_source; policy)
        @test multiple isa DocumentCountError
        @test multiple.expected == 1
        @test multiple.actual == 3
        @test mark_coordinates(multiple.mark) == (10, 3, 0)

        @test validate_events(parse_events("");
                              policy = SyntaxPolicy(document_count = 0)).document_count == 0
    end

    @testset "Duplicate scalar keys" begin
        policy = SyntaxPolicy(allow_duplicate_keys = false)

        duplicate = captured_policy_error("value: first\nvalue: second\n"; policy)
        @test duplicate isa DuplicateKeyError
        @test duplicate isa SyntaxPolicyError
        @test duplicate.key == "value"
        @test mark_coordinates(duplicate.mark) == (13, 2, 0)
        @test mark_coordinates(duplicate.first_mark) == (0, 1, 0)
        @test occursin("duplicate scalar mapping key \"value\"",
                       sprint(showerror, duplicate))
        @test occursin("first defined at line 1, column 0", sprint(showerror, duplicate))

        quoted = captured_policy_error("key: first\n\"key\": second\n"; policy)
        @test quoted isa DuplicateKeyError
        @test quoted.key == "key"

        escaped = captured_policy_error("key: first\n\"k\\u0065y\": second\n"; policy)
        @test escaped isa DuplicateKeyError
        @test escaped.key == "key"

        tagged = captured_policy_error("!!str key: first\n!local key: second\n"; policy)
        @test tagged isa DuplicateKeyError
        @test tagged.key == "key"

        separate_scopes = """
        first:
          value: one
        second:
          value: two
        """
        @test captured_policy_error(separate_scopes; policy) === nothing
        @test captured_policy_error("1: first\n01: second\n"; policy) === nothing

        complex_keys = """
        ? [one, two]
        : first
        ? [one, two]
        : second
        plain: first
        plain: second
        """
        complex_duplicate = captured_policy_error(complex_keys; policy)
        @test complex_duplicate isa DuplicateKeyError
        @test complex_duplicate.key == "plain"

        duplicate_complex_keys = """
        ? [one, two]
        : first
        ? [one, two]
        : second
        """
        @test captured_policy_error(duplicate_complex_keys; policy) === nothing

        empty_key = captured_policy_error("\"\": first\n\"\": second\n"; policy)
        @test empty_key isa DuplicateKeyError
        @test isempty(empty_key.key)
    end

    @testset "Flow collections" begin
        policy = SyntaxPolicy(allow_flow_collections = false)
        mapping = captured_policy_error("value: {nested: data}\n"; policy)
        sequence = captured_policy_error("value: [first, second]\n"; policy)
        @test mapping isa DisallowedSyntaxError
        @test mapping.feature === :flow_mapping
        @test sequence isa DisallowedSyntaxError
        @test sequence.feature === :flow_sequence
        @test captured_policy_error("value:\n  nested: data\n"; policy) === nothing
        @test captured_policy_error("value:\n  - first\n  - second\n"; policy) === nothing
    end

    @testset "Anchors and aliases" begin
        anchor_policy = SyntaxPolicy(allow_anchors = false)
        for source in ("value: &scalar data\n", "value: &mapping\n  nested: data\n", "value: &sequence\n  - data\n")
            exception = captured_policy_error(source; policy = anchor_policy)
            @test exception isa DisallowedSyntaxError
            @test exception.feature === :anchor
            @test exception.mark.line == 1
        end

        alias_policy = SyntaxPolicy(allow_aliases = false)
        alias = captured_policy_error("source: &value data\ncopy: *value\n";
                                      policy = alias_policy)
        @test alias isa DisallowedSyntaxError
        @test alias.feature === :alias
        @test alias.mark.line == 2

        @test captured_policy_error("source: &value data\ncopy: *value\n";
                                    policy = SyntaxPolicy()) === nothing
    end

    @testset "Tags and directives" begin
        tag_policy = SyntaxPolicy(allow_tags = false)
        for source in ("value: !local data\n", "value: !local {nested: data}\n", "value: !local [data]\n")
            exception = captured_policy_error(source; policy = tag_policy)
            @test exception isa DisallowedSyntaxError
            @test exception.feature === :tag
        end

        tag_directive_source = "%TAG !e! tag:example.com,2026:\n---\n!e!value data\n"
        tag_directive = captured_policy_error(tag_directive_source; policy = tag_policy)
        @test tag_directive isa DisallowedSyntaxError
        @test tag_directive.feature === :tag_directive
        @test mark_coordinates(tag_directive.mark) == (0, 1, 0)
        @test captured_policy_error("%YAML 1.1\n---\ndata\n"; policy = tag_policy) ===
              nothing

        directive_policy = SyntaxPolicy(allow_unknown_directives = false)
        directive_source = "%APPLICATION strict\n---\ndata\n"
        directive = captured_policy_error(directive_source; policy = directive_policy)
        @test directive isa DisallowedSyntaxError
        @test directive.feature === :unknown_directive
        @test mark_coordinates(directive.mark) == (0, 1, 0)

        parser_directive = captured_policy_error(directive_source;
                                                 policy = directive_policy,
                                                 unknown_directives = :error)
        @test parser_directive isa ScannerError
    end

    @testset "Merge keys" begin
        policy = SyntaxPolicy(allow_merge_keys = false)
        sources = ("material:\n  <<:\n    value: data\n", "material:\n  ? <<\n  : value\n",
                   "material: {<<: {value: data}}\n")
        for source in sources
            exception = captured_policy_error(source; policy)
            @test exception isa DisallowedSyntaxError
            @test exception.feature === :merge_key
        end

        @test captured_policy_error("\"<<\": value\n"; policy) === nothing
        @test captured_policy_error("key: <<\n"; policy) === nothing
        @test captured_policy_error("- <<\n"; policy) === nothing

        tagged_merge = captured_policy_error("!!merge \"ordinary\": value\n"; policy)
        @test tagged_merge isa DisallowedSyntaxError
        @test tagged_merge.feature === :merge_key

        tag_first_policy = SyntaxPolicy(allow_tags = false, allow_merge_keys = false)
        tag_first = captured_policy_error("!!merge \"ordinary\": value\n";
                                          policy = tag_first_policy)
        @test tag_first isa DisallowedSyntaxError
        @test tag_first.feature === :tag
    end

    @testset "Streaming and malformed input" begin
        events = collect(parse_events("{key: value}\n"))
        flow_index = findfirst(event -> event isa MappingStartEvent, events)
        stop_after_flow = StopAfterEvents(events, flow_index)
        exception = try
            validate_events(stop_after_flow;
                            policy = SyntaxPolicy(allow_flow_collections = false))
            nothing
        catch caught
            caught
        end
        @test exception isa DisallowedSyntaxError
        @test exception.feature === :flow_mapping

        @test_throws ParserError validate_events(parse_events("[first,,second]"))
        @test_throws ScannerError validate_events(parse_events("value: %"))

        mark = Mark(0, 1, 0)
        @test_throws ArgumentError validate_events(Any[1])
        @test_throws ArgumentError validate_events(Event[SequenceEndEvent(mark, mark)])
        @test_throws ArgumentError validate_events(Event[MappingStartEvent(mark, mark,
                                                                           nothing, nothing,
                                                                           true, false)])
        @test_throws ArgumentError validate_events(Event[MappingStartEvent(mark, mark,
                                                                           nothing, nothing,
                                                                           true, false),
                                                         ScalarEvent(mark, mark, nothing,
                                                                     nothing, (true, false),
                                                                     "key", nothing),
                                                         MappingEndEvent(mark, mark)])
    end
end
