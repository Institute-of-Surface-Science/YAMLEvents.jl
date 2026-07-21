# YAML.jl 0.4.16 has no public event iterator. Keep the coupling to its
# parser internals isolated in the backend conversion layers; Project.toml
# pins the exact backend version.
mutable struct _EventIteratorState
    tokenstream::YAML.TokenStream
    stream::YAML.EventStream
    mark_converter::_MarkConverter
    encoding::String
    unknown_directive_mode::Symbol
    directive_prologue_scanned::Bool
    next_unknown_directive::Int
    previous_backend_event::Union{Event, Nothing}
    done::Bool
end

function _convert_mark(state::_EventIteratorState, mark::YAML.Mark)
    converter = state.mark_converter
    converter.tokenstream === nothing || _scan_mark_mapping!(converter, mark.index)

    override = get(converter.mark_overrides, _mark_key(mark), nothing)
    normalized_index = override === nothing ? _normalized_index(converter, mark.index) :
                       override[1]

    correction_count = searchsortedlast(converter.newline_corrections, normalized_index)
    original_index = normalized_index + UInt64(correction_count)
    column = if override !== nothing
        override[2]
    elseif converter.line_start_positions === nothing
        mark.column
    else
        normalized_index - converter.line_start_positions[Int(mark.line)]
    end
    return Mark(original_index, mark.line, column)
end

_convert_mark(::_EventIteratorState, ::Nothing) = nothing

function _marks(state, event)
    return _convert_mark(state, event.start_mark), _convert_mark(state, event.end_mark)
end

_decode_backend_tag(::Nothing, ::Mark) = nothing

function _decode_backend_tag(tag::String, problem_mark::Mark)
    isascii(tag) && return tag
    bytes = UInt8[]
    for char in tag
        codepoint = UInt32(char)
        if codepoint <= 0xff
            push!(bytes, UInt8(codepoint))
        else
            append!(bytes, codeunits(string(char)))
        end
    end

    decoded = String(bytes)
    isvalid(decoded) || throw(ScannerError("while scanning a tag", problem_mark,
                       "tag URI contains an invalid UTF-8 escape sequence",
                       problem_mark))
    return decoded
end

function _throw_scalar_error(state::_EventIteratorState, event, start_mark::Mark)
    scalar_error = get(state.mark_converter.scalar_errors, _mark_key(event.end_mark),
                       nothing)
    scalar_error === nothing && return nothing
    problem, problem_mark = scalar_error
    throw(ScannerError("while scanning a double-quoted scalar", start_mark, problem,
                       problem_mark))
end

function _convert_event(state, event::YAML.StreamStartEvent)
    return StreamStartEvent(_marks(state, event)..., state.encoding)
end

_convert_event(state, event::YAML.StreamEndEvent) = StreamEndEvent(_marks(state, event)...)

function _convert_event(state, event::YAML.DocumentStartEvent)
    marks = _marks(state, event)
    if event.version !== nothing && event.version > (1, 1)
        throw(ParserError(nothing, nothing,
                          "found incompatible YAML document (version 1.1 or earlier is required)",
                          marks[1], nothing))
    end
    tags = if event.tags === nothing
        nothing
    else
        Dict(handle => _decode_backend_tag(prefix, marks[1])
             for (handle, prefix) in event.tags)
    end
    return DocumentStartEvent(marks..., event.explicit, event.version, tags)
end

function _convert_event(state, event::YAML.DocumentEndEvent)
    return DocumentEndEvent(_marks(state, event)..., event.explicit)
end

function _convert_event(state, event::YAML.AliasEvent)
    return AliasEvent(_marks(state, event)..., event.anchor)
end

function _convert_event(state, event::YAML.ScalarEvent)
    marks = _marks(state, event)
    _throw_scalar_error(state, event, marks[1])
    implicit = (Bool(event.implicit[1]), Bool(event.implicit[2]))
    tag = _decode_backend_tag(event.tag, marks[1])
    return ScalarEvent(marks..., event.anchor, tag, implicit, event.value, event.style)
end

function _convert_event(state, event::YAML.SequenceStartEvent)
    marks = _marks(state, event)
    tag = _decode_backend_tag(event.tag, marks[1])
    return SequenceStartEvent(marks..., event.anchor, tag, event.implicit, event.flow_style)
end

function _convert_event(state, event::YAML.SequenceEndEvent)
    SequenceEndEvent(_marks(state, event)...)
end

function _convert_event(state, event::YAML.MappingStartEvent)
    marks = _marks(state, event)
    tag = _decode_backend_tag(event.tag, marks[1])
    return MappingStartEvent(marks..., event.anchor, tag, event.implicit, event.flow_style)
end

function _convert_event(state, event::YAML.MappingEndEvent)
    MappingEndEvent(_marks(state, event)...)
end

function _convert_error(state, error::YAML.ScannerError)
    return ScannerError(error.context, _convert_mark(state, error.context_mark),
                        error.problem, _convert_mark(state, error.problem_mark))
end

function _convert_error(state, error::YAML.ParserError)
    problem = error.problem
    problem_mark = error.problem_mark
    if problem_mark === nothing &&
       problem !== nothing &&
       startswith(problem, "expected '<document start>'")
        token = YAML.peek(state.tokenstream)
        if token !== nothing
            problem = "expected '<document start>', but found $(typeof(token))"
            problem_mark = YAML.firstmark(token)
        end
    end
    return ParserError(error.context, _convert_mark(state, error.context_mark), problem,
                       _convert_mark(state, problem_mark), error.note)
end

function _source_scanner_position(state::_EventIteratorState)
    converter = state.mark_converter
    converter.source === nothing && return nothing
    return _source_position_at_input(converter.source, state.tokenstream)
end

# YAML.jl 0.4.16 also parses a one-digit block-scalar indentation indicator
# and two-digit tag URI escapes. Those conversions are bounded; only directive
# components and Unicode-to-Char conversion require source-error normalization.
function _escaped_codepoint(source::String, first_digit::Int, digits::Int)
    index = first_digit
    codepoint = UInt32(0)
    for _ in 1:digits
        index <= ncodeunits(source) || return nothing
        digit = _ascii_hex_value(source[index])
        digit === nothing && return nothing
        codepoint = UInt32(16) * codepoint + digit
        index = nextind(source, index)
    end
    return codepoint
end

function _opening_double_quote(source::String, before::Int)
    quote_index = prevind(source, before)
    while quote_index >= firstindex(source)
        if source[quote_index] != '"'
            quote_index = prevind(source, quote_index)
            continue
        end
        preceding_backslashes = 0
        index = prevind(source, quote_index)
        while index >= firstindex(source) && source[index] == '\\'
            preceding_backslashes += 1
            index = prevind(source, index)
        end
        iseven(preceding_backslashes) && return quote_index
        quote_index = index
    end
    return nothing
end

function _unicode_escape_error(state::_EventIteratorState,
                               exception::Union{Base.CodePointError, OverflowError},
                               source_position::UInt64,
                               integer_maximum::Integer = typemax(Int))
    converter = state.mark_converter
    source = converter.source
    first_digit = _source_index_at_position(source, source_position)
    first_digit === nothing && return nothing
    first_digit > firstindex(source) || return nothing
    escape_code_index = prevind(source, first_digit)
    escape_code_index > firstindex(source) || return nothing
    backslash_index = prevind(source, escape_code_index)
    backslash_index >= firstindex(source) || return nothing
    source[backslash_index] == '\\' || return nothing
    escape_code = source[escape_code_index]
    digits = get(YAML.ESCAPE_CODES, escape_code, nothing)
    digits === nothing && return nothing
    codepoint = _escaped_codepoint(source, first_digit, digits)
    codepoint === nothing && return nothing
    isvalid(Char, codepoint) && return nothing
    if exception isa Base.CodePointError
        exception.code == codepoint || return nothing
    else
        codepoint > integer_maximum || return nothing
    end

    quote_index = _opening_double_quote(source, backslash_index)
    quote_index === nothing && return nothing
    context_position = _source_position_at_index(source, quote_index)
    return ScannerError("while scanning a double-quoted scalar",
                        _mark_at_source_position(converter, context_position),
                        "escape sequence contains invalid Unicode code point $(_unicode_codepoint_name(codepoint))",
                        _mark_at_source_position(converter, source_position))
end

function _line_start_index(source::String, position::Int)
    index = prevind(source, position)
    while index >= firstindex(source)
        _is_line_break(source[index]) && return nextind(source, index)
        index = prevind(source, index)
    end
    return firstindex(source)
end

function _yaml_directive_component(source::String, first_digit::Int)
    directive_index = _line_start_index(source, first_digit)
    source[directive_index] == '\ufeff' &&
        (directive_index = nextind(source, directive_index))
    startswith(SubString(source, directive_index), "%YAML") || return nothing

    index = nextind(source, directive_index, 5)
    while index <= ncodeunits(source) && source[index] in (' ', ':')
        index = nextind(source, index)
    end
    major_start = index
    while index <= ncodeunits(source) && '0' <= source[index] <= '9'
        index = nextind(source, index)
    end
    if first_digit != major_start
        index <= ncodeunits(source) && source[index] == '.' || return nothing
        index = nextind(source, index)
        first_digit == index || return nothing
    end

    last_digit = first_digit
    while last_digit <= ncodeunits(source) && '0' <= source[last_digit] <= '9'
        last_digit = nextind(source, last_digit)
    end
    last_digit > first_digit || return nothing
    component = SubString(source, first_digit, prevind(source, last_digit))
    tryparse(Int, component) === nothing || return nothing
    return directive_index
end

function _directive_overflow_error(state::_EventIteratorState, source_position::UInt64)
    converter = state.mark_converter
    source = converter.source
    first_digit = _source_index_at_position(source, source_position)
    first_digit === nothing && return nothing
    first_digit <= ncodeunits(source) || return nothing
    directive_index = _yaml_directive_component(source, first_digit)
    directive_index === nothing && return nothing
    context_position = _source_position_at_index(source, directive_index)
    return ScannerError("while scanning a directive",
                        _mark_at_source_position(converter, context_position),
                        "YAML directive contains an integer that is too large",
                        _mark_at_source_position(converter, source_position))
end

function _source_scanner_error(state::_EventIteratorState,
                               exception::Union{Base.CodePointError, OverflowError},
                               backtrace)
    kind = _scanner_conversion_kind(exception, backtrace)
    kind === nothing && return nothing
    source_position = _source_scanner_position(state)
    source_position === nothing && return nothing
    if kind === :unicode
        return _unicode_escape_error(state, exception, source_position)
    end
    return _directive_overflow_error(state, source_position)
end

function _with_error_conversion(operation, state::_EventIteratorState)
    return Logging.with_logger(Logging.NullLogger()) do
        try
            return operation()
        catch exception
            if exception isa Union{YAML.ScannerError, YAML.ParserError}
                throw(_convert_error(state, exception))
            elseif exception isa Union{Base.CodePointError, OverflowError}
                converted = _source_scanner_error(state, exception, catch_backtrace())
                converted === nothing || throw(converted)
            end
            rethrow()
        end
    end
end
