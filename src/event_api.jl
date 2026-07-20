# YAML.jl 0.4.16 advances its source index twice for most characters, once for
# tokenized BOMs, and not at all in a handful of quoted-scalar and tag-URI
# scanner paths. Replay only inputs containing those constructs and retain
# sparse corrections so public marks still refer to the original characters.
mutable struct _MarkConverter
    source::Union{String, Nothing}
    newline_corrections::Vector{UInt64}
    character_count::UInt64
    line_start_positions::Union{Vector{UInt64}, Nothing}
    tokenstream::Union{YAML.TokenStream, Nothing}
    scanned_index::UInt64
    bom_end_indices::Vector{UInt64}
    skipped_indices::Vector{UInt64}
    source_cursor::Int
    source_position::UInt64
    mark_overrides::Dict{NTuple{3, UInt64}, Tuple{UInt64, UInt64}}
    scalar_errors::Dict{NTuple{3, UInt64}, Tuple{String, Mark}}
    reset_pending::Bool
    done::Bool
end

mutable struct _EventIteratorState
    tokenstream::YAML.TokenStream
    stream::YAML.EventStream
    mark_converter::_MarkConverter
    encoding::String
    previous_event::Union{Event, Nothing}
    done::Bool
end

# YAML.jl 0.4.16 has no public event iterator. Keep all coupling to its parser
# internals in this file; Project.toml pins the exact backend version.

"""
    YAMLEventIterator

A forward-only iterator over the syntactic events in a YAML stream.

Create an iterator with [`parse_events`](@ref). Parser errors are raised when
the iterator reaches malformed input. Each iterator may be consumed only once.
"""
struct YAMLEventIterator
    _state::_EventIteratorState
end

Base.IteratorSize(::Type{YAMLEventIterator}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{YAMLEventIterator}) = Base.HasEltype()
Base.eltype(::Type{YAMLEventIterator}) = Event

_mark_key(mark::YAML.Mark) = (mark.index, mark.line, mark.column)

function _normalized_index(converter::_MarkConverter, backend_index::UInt64)
    bom_count = searchsortedlast(converter.bom_end_indices, backend_index)
    skipped_count = searchsortedlast(converter.skipped_indices, backend_index)
    adjusted_index = backend_index - 1 + UInt64(bom_count + 2 * skipped_count)
    iseven(adjusted_index) ||
        error("YAML backend returned an unsupported source index $backend_index")
    normalized_index = adjusted_index ÷ 2
    normalized_index <= converter.character_count ||
        error("YAML backend returned an invalid source index $backend_index")
    return normalized_index
end

function _source_index!(converter::_MarkConverter, target_position::UInt64)
    target_position >= converter.source_position ||
        error("YAML backend returned source marks out of order")
    source = converter.source
    while converter.source_position < target_position
        converter.source_cursor = nextind(source, converter.source_cursor)
        converter.source_position += 1
    end
    return converter.source_cursor
end

_is_line_break(char::Char) = char in ('\n', '\u0085', '\u2028', '\u2029')
_is_inline_space(char::Char) = char == ' ' || char == '\t'

function _ascii_hex_value(char::Char)
    if '0' <= char <= '9'
        return UInt32(char) - UInt32('0')
    elseif 'A' <= char <= 'F'
        return UInt32(char) - UInt32('A') + UInt32(10)
    elseif 'a' <= char <= 'f'
        return UInt32(char) - UInt32('a') + UInt32(10)
    end
    return nothing
end

function _unicode_codepoint_name(codepoint::UInt32)
    width = codepoint <= 0xffff ? 4 : 8
    return "U+" * uppercase(string(codepoint; base = 16, pad = width))
end

function _line_start_positions(source::String)
    positions = UInt64[0]
    source_position = UInt64(0)
    for char in source
        source_position += 1
        _is_line_break(char) && push!(positions, source_position)
    end
    return positions
end

function _advance_normal(source::String, source_index::Int, source_position::UInt64,
                         backend_index::UInt64, line::UInt64)
    char = source[source_index]
    return nextind(source, source_index), source_position + 1, backend_index + 2,
           line + UInt64(_is_line_break(char))
end

function _advance_skipped!(converter::_MarkConverter, source_index::Int,
                           source_position::UInt64, backend_index::UInt64)
    push!(converter.skipped_indices, backend_index)
    return nextind(converter.source, source_index), source_position + 1
end

function _record_flow_breaks!(converter::_MarkConverter, source_index::Int,
                              source_position::UInt64, backend_index::UInt64, line::UInt64)
    source = converter.source
    while true
        while source_index <= ncodeunits(source) && _is_inline_space(source[source_index])
            source_index,
            source_position = _advance_skipped!(converter, source_index, source_position,
                                                backend_index)
        end
        if source_index <= ncodeunits(source) && _is_line_break(source[source_index])
            source_index, source_position, backend_index,
            line = _advance_normal(source, source_index, source_position, backend_index,
                                   line)
        else
            return source_index, source_position, backend_index, line
        end
    end
end

function _record_quoted_corrections!(converter::_MarkConverter, token::YAML.ScalarToken)
    start_mark = YAML.firstmark(token)
    end_mark = YAML.lastmark(token)
    source_position = _normalized_index(converter, start_mark.index)
    source_index = _source_index!(converter, source_position)
    source = converter.source
    style = token.style
    source[source_index] == style || error("could not align YAML quoted scalar source")
    backend_index = start_mark.index
    line = start_mark.line
    source_index, source_position, backend_index,
    line = _advance_normal(source, source_index, source_position, backend_index, line)

    while source_index <= ncodeunits(source)
        char = source[source_index]
        next_index = nextind(source, source_index)
        next_char = next_index <= ncodeunits(source) ? source[next_index] : '\0'

        if char == style && !(style == '\'' && next_char == '\'')
            break
        elseif _is_inline_space(char)
            while source_index <= ncodeunits(source) &&
                _is_inline_space(source[source_index])
                source_index, source_position, backend_index,
                line = _advance_normal(source, source_index, source_position, backend_index,
                                       line)
            end
            if source_index <= ncodeunits(source) && _is_line_break(source[source_index])
                source_index, source_position, backend_index,
                line = _advance_normal(source, source_index, source_position, backend_index,
                                       line)
                source_index, source_position, backend_index,
                line = _record_flow_breaks!(converter, source_index, source_position,
                                            backend_index, line)
            end
        elseif _is_line_break(char)
            source_index, source_position, backend_index,
            line = _advance_normal(source, source_index, source_position, backend_index,
                                   line)
            source_index, source_position, backend_index,
            line = _record_flow_breaks!(converter, source_index, source_position,
                                        backend_index, line)
        elseif style == '\'' && char == '\'' && next_char == '\''
            source_index, source_position, backend_index,
            line = _advance_normal(source, source_index, source_position, backend_index,
                                   line)
            source_index, source_position, backend_index,
            line = _advance_normal(source, source_index, source_position, backend_index,
                                   line)
        elseif (style == '"' && char == '\'') ||
               (style == '\'' && (char == '"' || char == '\\'))
            source_index,
            source_position = _advance_skipped!(converter, source_index, source_position,
                                                backend_index)
        elseif style == '"' && char == '\\'
            source_index,
            source_position = _advance_skipped!(converter, source_index, source_position,
                                                backend_index)
            escaped = source[source_index]
            if haskey(YAML.ESCAPE_REPLACEMENTS, escaped)
                source_index,
                source_position = _advance_skipped!(converter, source_index,
                                                    source_position, backend_index)
            elseif haskey(YAML.ESCAPE_CODES, escaped)
                digits = YAML.ESCAPE_CODES[escaped]
                source_index,
                source_position = _advance_skipped!(converter, source_index,
                                                    source_position, backend_index)
                escape_position = source_position
                codepoint = UInt32(0)
                for _ in 1:digits
                    digit = _ascii_hex_value(source[source_index])
                    digit === nothing && error("could not align YAML Unicode escape")
                    codepoint = UInt32(16) * codepoint + digit
                    source_index, source_position, backend_index,
                    line = _advance_normal(source, source_index, source_position,
                                           backend_index, line)
                end
                if !isvalid(Char, codepoint)
                    key = _mark_key(end_mark)
                    haskey(converter.scalar_errors, key) ||
                        (converter.scalar_errors[key] = ("escape sequence contains invalid Unicode code point $(_unicode_codepoint_name(codepoint))",
                                                         _mark_at_source_position(converter,
                                                                                  escape_position)))
                end
            elseif _is_line_break(escaped)
                source_index, source_position, backend_index,
                line = _advance_normal(source, source_index, source_position, backend_index,
                                       line)
                source_index, source_position, backend_index,
                line = _record_flow_breaks!(converter, source_index, source_position,
                                            backend_index, line)
            else
                error("could not align YAML double-quoted escape")
            end
        else
            source_index, source_position, backend_index,
            line = _advance_normal(source, source_index, source_position, backend_index,
                                   line)
        end
    end

    source_index <= ncodeunits(source) || error("unterminated YAML quoted scalar")
    source_index, source_position, backend_index,
    line = _advance_normal(source, source_index, source_position, backend_index, line)
    backend_index == end_mark.index || error("could not align YAML quoted scalar mark")
    converter.source_cursor = source_index
    converter.source_position = source_position
    return nothing
end

function _record_uri_corrections!(converter::_MarkConverter, token;
                                  initial_percent_is_normal::Bool = false)
    start_mark = YAML.firstmark(token)
    end_mark = YAML.lastmark(token)
    source_position = _normalized_index(converter, start_mark.index)
    source_index = _source_index!(converter, source_position)
    source = converter.source
    backend_index = start_mark.index
    line = start_mark.line
    first_character = true

    while backend_index < end_mark.index
        source_index <= ncodeunits(source) || error("could not align YAML tag source")
        char = source[source_index]
        if char == '%' && !(initial_percent_is_normal && first_character)
            source_index,
            source_position = _advance_skipped!(converter, source_index, source_position,
                                                backend_index)
        else
            source_index, source_position, backend_index,
            line = _advance_normal(source, source_index, source_position, backend_index,
                                   line)
        end
        first_character = false
    end

    backend_index == end_mark.index || error("could not align YAML tag mark")
    converter.source_cursor = source_index
    converter.source_position = source_position
    return nothing
end

function _record_token_corrections!(converter::_MarkConverter, token)
    if token isa YAML.ByteOrderMarkToken
        end_mark = YAML.lastmark(token)
        push!(converter.bom_end_indices, end_mark.index)
    elseif token isa YAML.ScalarToken && token.style in ('\'', '"')
        _record_quoted_corrections!(converter, token)
    elseif token isa YAML.TagToken
        _record_uri_corrections!(converter, token)
    elseif token isa YAML.DirectiveToken && token.name == "TAG"
        _record_uri_corrections!(converter, token; initial_percent_is_normal = true)
    end
    return nothing
end

struct _ContextCharacter
    position::UInt64
    character::Char
    mark::Mark
end

function _context_characters(input::_PreparedInput)
    characters = _ContextCharacter[]
    position = UInt64(0)
    line = UInt64(1)
    column = UInt64(0)

    for char in input.source
        if char == '\ufeff' || !_is_yaml_printable(char)
            correction_count = searchsortedlast(input.newline_corrections, position)
            mark = Mark(position + UInt64(correction_count), line, column)
            codepoint = UInt32(char)
            quoted_character = codepoint == 0x09 || 0x20 <= codepoint <= 0x10ffff
            quoted_character || throw(ScannerError(nothing, nothing,
                               "found non-printable character $(_codepoint_name(char))",
                               mark))
            # An initial BOM is unambiguously the stream encoding prefix. Avoid
            # tokenizing an otherwise ordinary BOM-prefixed document.
            char == '\ufeff' && position == 0 ||
                push!(characters, _ContextCharacter(position, char, mark))
        end

        position += 1
        if _is_line_break(char)
            line += 1
            column = 0
        else
            column += 1
        end
    end
    return characters
end

function _validation_converter(input::_PreparedInput)
    return _MarkConverter(input.source, input.newline_corrections, input.character_count,
                          nothing, nothing, 0, UInt64[], UInt64[], firstindex(input.source),
                          0, Dict{NTuple{3, UInt64}, Tuple{UInt64, UInt64}}(),
                          Dict{NTuple{3, UInt64}, Tuple{String, Mark}}(), false, false)
end

function _resolve_quoted_characters!(resolved::BitVector,
                                     characters::Vector{_ContextCharacter},
                                     positions::Vector{UInt64}, start_position::UInt64,
                                     end_position::UInt64)
    first_character = searchsortedfirst(positions, start_position)
    last_character = searchsortedfirst(positions, end_position) - 1
    for index in first_character:last_character
        resolved[index] = true
    end
    return nothing
end

function _throw_unquoted_character(character::_ContextCharacter)
    character.character == '\ufeff' && _throw_misplaced_bom(character.mark)
    throw(ScannerError(nothing, nothing,
                       "found non-printable character $(_codepoint_name(character.character))",
                       character.mark))
end

function _validate_pending_bom(pending, token)
    pending === nothing && return nothing
    character, seen_document_syntax, directives_pending, after_document_end = pending
    if seen_document_syntax
        starts_document = token isa Union{YAML.DirectiveToken, YAML.DocumentStartToken}
        ends_after_suffix = token isa YAML.StreamEndToken && after_document_end
        (directives_pending || !(starts_document || ends_after_suffix)) &&
            _throw_misplaced_bom(character.mark)
    end
    return nothing
end

function _validate_scanner_failure(characters::Vector{_ContextCharacter},
                                   positions::Vector{UInt64}, converter::_MarkConverter,
                                   exception::YAML.ScannerError)
    failure_position = try
        _normalized_index(converter, exception.problem_mark.index)
    catch conversion_error
        conversion_error isa ErrorException || rethrow()
        return nothing
    end
    character_index = searchsortedfirst(positions, failure_position)
    if character_index <= length(characters) &&
       positions[character_index] == failure_position
        _throw_unquoted_character(characters[character_index])
    end
    return nothing
end

function _validate_source_characters(input::_PreparedInput)
    characters = _context_characters(input)
    isempty(characters) && return nothing

    positions = [character.position for character in characters]
    resolved = falses(length(characters))
    converter = _validation_converter(input)
    stream = YAML.TokenStream(IOBuffer(input.source))
    reset_pending = false
    pending_bom = nothing
    seen_document_syntax = false
    directives_pending = false
    after_document_end = false
    complete = false
    scanned_position = UInt64(0)

    while true
        token = try
            Logging.with_logger(Logging.NullLogger()) do
                YAML.forward!(stream)
            end
        catch exception
            if exception isa YAML.ScannerError
                _validate_scanner_failure(characters, positions, converter, exception)
                break
            elseif exception isa Union{Base.CodePointError, OverflowError}
                break
            end
            rethrow()
        end

        if token === nothing && reset_pending
            YAML.reset!(stream)
            reset_pending = false
            continue
        elseif token === nothing
            complete = true
            break
        end
        reset_pending = token isa YAML.DocumentEndToken

        start_position = _normalized_index(converter, YAML.firstmark(token).index)
        _record_token_corrections!(converter, token)
        end_position = _normalized_index(converter, YAML.lastmark(token).index)
        scanned_position = max(scanned_position, end_position)

        if token isa YAML.ScalarToken && token.style in ('\'', '"')
            _resolve_quoted_characters!(resolved, characters, positions, start_position,
                                        end_position)
        end

        if token isa YAML.StreamStartToken
            continue
        end
        _validate_pending_bom(pending_bom, token)
        pending_bom = nothing

        if token isa YAML.ByteOrderMarkToken
            character_index = searchsortedfirst(positions, start_position)
            if character_index <= length(characters) &&
               positions[character_index] == start_position &&
               characters[character_index].character == '\ufeff'
                resolved[character_index] = true
                pending_bom = (characters[character_index], seen_document_syntax,
                               directives_pending, after_document_end)
            end
        elseif token isa YAML.StreamEndToken
            continue
        else
            seen_document_syntax = true
            if token isa YAML.DirectiveToken
                directives_pending = true
                after_document_end = false
            elseif token isa YAML.DocumentEndToken
                directives_pending = false
                after_document_end = true
            else
                directives_pending = false
                after_document_end = false
            end
        end
    end

    for index in eachindex(characters)
        resolved[index] && continue
        complete || characters[index].position < scanned_position || continue
        _throw_unquoted_character(characters[index])
    end
    return nothing
end

function _source_position_at_input(source::String, tokenstream::YAML.TokenStream)
    buffered_input = tokenstream.input
    byte_position = position(buffered_input.input)
    fetched_characters = if byte_position == 0
        0
    else
        length(SubString(source, firstindex(source), prevind(source, byte_position + 1)))
    end
    available_characters = count(!=('\0'),
                                 @view(buffered_input.buffer[(buffered_input.offset + 1):(buffered_input.offset + buffered_input.avail)]))
    return UInt64(fetched_characters - available_characters)
end

function _source_position_at_input(converter::_MarkConverter)
    return _source_position_at_input(converter.source, converter.tokenstream)
end

function _source_line_column(source::String, target_position::UInt64)
    source_index = firstindex(source)
    position = UInt64(0)
    line = UInt64(1)
    column = UInt64(0)
    while position < target_position
        char = source[source_index]
        if _is_line_break(char)
            line += 1
            column = 0
        else
            column += 1
        end
        source_index = nextind(source, source_index)
        position += 1
    end
    return line, column
end

function _mark_at_source_position(converter::_MarkConverter, source_position::UInt64)
    correction_count = searchsortedlast(converter.newline_corrections, source_position)
    line, column = _source_line_column(converter.source, source_position)
    return Mark(source_position + UInt64(correction_count), line, column)
end

function _record_error_override!(converter::_MarkConverter, exception::YAML.ScannerError)
    # Scanner errors may occur between two identical backend indices after a
    # skipped character. The replay scanner's buffered-input cursor is the only
    # unambiguous position for that problem mark.
    mark = exception.problem_mark
    source_position = _source_position_at_input(converter)
    _, column = _source_line_column(converter.source, source_position)
    converter.mark_overrides[_mark_key(mark)] = (source_position, column)
    return nothing
end

function _next_mapping_token!(converter::_MarkConverter)
    while true
        token = try
            Logging.with_logger(Logging.NullLogger()) do
                YAML.forward!(converter.tokenstream)
            end
        catch exception
            if exception isa YAML.ScannerError
                _record_error_override!(converter, exception)
                converter.done = true
                return nothing
            elseif exception isa Union{Base.CodePointError, OverflowError}
                converter.done = true
                return nothing
            end
            rethrow()
        end

        if token === nothing && converter.reset_pending
            YAML.reset!(converter.tokenstream)
            converter.reset_pending = false
        elseif token === nothing
            converter.done = true
            return nothing
        else
            converter.reset_pending = token isa YAML.DocumentEndToken
            return token
        end
    end
end

function _scan_mark_mapping!(converter::_MarkConverter, backend_index::UInt64)
    while !converter.done && converter.scanned_index < backend_index
        token = _next_mapping_token!(converter)
        token === nothing && break
        _record_token_corrections!(converter, token)
        end_mark = YAML.lastmark(token)
        converter.scanned_index = max(converter.scanned_index, end_mark.index)
    end
    return nothing
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
function _escaped_codepoint(characters::Vector{Char}, first_digit::Int, digits::Int)
    last_digit = first_digit + digits - 1
    last_digit <= length(characters) || return nothing
    codepoint = UInt32(0)
    for index in first_digit:last_digit
        digit = _ascii_hex_value(characters[index])
        digit === nothing && return nothing
        codepoint = UInt32(16) * codepoint + digit
    end
    return codepoint
end

function _opening_double_quote(characters::Vector{Char}, before::Int)
    for quote_index in (before - 1):-1:firstindex(characters)
        characters[quote_index] == '"' || continue
        preceding_backslashes = 0
        index = quote_index - 1
        while index >= firstindex(characters) && characters[index] == '\\'
            preceding_backslashes += 1
            index -= 1
        end
        iseven(preceding_backslashes) && return quote_index
    end
    return nothing
end

function _unicode_escape_error(state::_EventIteratorState, exception::Base.CodePointError,
                               source_position::UInt64)
    converter = state.mark_converter
    characters = collect(converter.source)
    first_digit = Int(source_position) + 1
    escape_code_index = first_digit - 1
    backslash_index = escape_code_index - 1
    backslash_index >= firstindex(characters) || return nothing
    characters[backslash_index] == '\\' || return nothing
    escape_code = characters[escape_code_index]
    digits = get(YAML.ESCAPE_CODES, escape_code, nothing)
    digits === nothing && return nothing
    codepoint = _escaped_codepoint(characters, first_digit, digits)
    codepoint === nothing && return nothing
    exception.code == codepoint || return nothing
    isvalid(Char, codepoint) && return nothing

    quote_index = _opening_double_quote(characters, backslash_index)
    quote_index === nothing && return nothing
    context_position = UInt64(quote_index - 1)
    return ScannerError("while scanning a double-quoted scalar",
                        _mark_at_source_position(converter, context_position),
                        "escape sequence contains invalid Unicode code point $(_unicode_codepoint_name(codepoint))",
                        _mark_at_source_position(converter, source_position))
end

function _line_start_index(characters::Vector{Char}, position::Int)
    index = position - 1
    while index >= firstindex(characters)
        _is_line_break(characters[index]) && return index + 1
        index -= 1
    end
    return firstindex(characters)
end

function _yaml_directive_component(characters::Vector{Char}, first_digit::Int)
    directive_index = _line_start_index(characters, first_digit)
    characters[directive_index] == '\ufeff' && (directive_index += 1)
    directive_index + 4 <= length(characters) || return nothing
    characters[directive_index:(directive_index + 4)] == collect("%YAML") || return nothing

    index = directive_index + 5
    while index <= length(characters) && characters[index] in (' ', ':')
        index += 1
    end
    major_start = index
    while index <= length(characters) && '0' <= characters[index] <= '9'
        index += 1
    end
    if first_digit != major_start
        index <= length(characters) && characters[index] == '.' || return nothing
        index += 1
        first_digit == index || return nothing
    end

    last_digit = first_digit
    while last_digit <= length(characters) && '0' <= characters[last_digit] <= '9'
        last_digit += 1
    end
    last_digit > first_digit || return nothing
    component = join(characters[first_digit:(last_digit - 1)])
    tryparse(Int, component) === nothing || return nothing
    return directive_index
end

function _directive_overflow_error(state::_EventIteratorState, source_position::UInt64)
    converter = state.mark_converter
    characters = collect(converter.source)
    first_digit = Int(source_position) + 1
    first_digit <= length(characters) || return nothing
    directive_index = _yaml_directive_component(characters, first_digit)
    directive_index === nothing && return nothing
    context_position = UInt64(directive_index - 1)
    return ScannerError("while scanning a directive",
                        _mark_at_source_position(converter, context_position),
                        "YAML directive contains an integer that is too large",
                        _mark_at_source_position(converter, source_position))
end

function _source_scanner_error(state::_EventIteratorState,
                               exception::Union{Base.CodePointError, OverflowError})
    source_position = _source_scanner_position(state)
    source_position === nothing && return nothing
    if exception isa Base.CodePointError
        return _unicode_escape_error(state, exception, source_position)
    end
    return _directive_overflow_error(state, source_position)
end

function _with_error_conversion(operation, state::_EventIteratorState)
    try
        return operation()
    catch exception
        if exception isa Union{YAML.ScannerError, YAML.ParserError}
            throw(_convert_error(state, exception))
        elseif exception isa Union{Base.CodePointError, OverflowError}
            converted = _source_scanner_error(state, exception)
            converted === nothing || throw(converted)
        end
        rethrow()
    end
end

function _forward!(state::_EventIteratorState)
    return _with_error_conversion(state) do
        YAML.forward!(state.stream)
    end
end

function _resume_after_explicit_document!(state::_EventIteratorState)
    # YAML.jl stops tokenization at every explicit document-end marker. Resume
    # the existing parser at its explicit-document state, skipping any repeated
    # suffix markers without pretending the following document is the first
    # (and therefore potentially implicit) document in a new stream.
    state.stream.end_of_stream = nothing
    _with_error_conversion(state) do
        while true
            state.tokenstream.done = false
            token = YAML.peek(state.tokenstream)
            token isa YAML.DocumentEndToken || break
            YAML.forward!(state.tokenstream)
        end
        if token isa YAML.ByteOrderMarkToken
            YAML.forward!(state.tokenstream)
            token = YAML.peek(state.tokenstream)
        end
        if !(token isa
             Union{YAML.DirectiveToken, YAML.DocumentStartToken, YAML.StreamEndToken})
            problem_mark = _convert_mark(state, YAML.firstmark(token))
            throw(ParserError(nothing, nothing,
                              "expected '<document start>', but found $(typeof(token))",
                              problem_mark, nothing))
        end
    end

    state.stream.state = YAML.parse_document_start
    return _forward!(state)
end

function Base.iterate(iterator::YAMLEventIterator, _ = nothing)
    state = iterator._state
    state.done && return nothing
    event = _forward!(state)
    event === nothing && return nothing

    # The internal parser treats an explicit document end (`...`) as the end
    # of its EventStream. Resume it while suppressing the artificial stream
    # boundary so this public iterator represents the complete YAML stream.
    if event isa YAML.StreamEndEvent &&
       state.previous_event isa DocumentEndEvent &&
       state.previous_event.explicit
        event = _resume_after_explicit_document!(state)
    end

    if event === nothing
        state.done = true
        return nothing
    end

    event = _convert_event(state, event)
    state.previous_event = event
    state.done = event isa StreamEndEvent
    return event, nothing
end

"""
    parse_events(input::Union{AbstractString, IO}) -> YAMLEventIterator

Parse `input` into a forward-only stream of [`Event`](@ref) objects without
constructing Julia values.

YAMLEvents implements YAML 1.1 syntax. An explicit directive declaring a newer
YAML version raises [`ParserError`](@ref) as the iterator advances.

The event stream preserves document boundaries, scalar styles, explicit tags,
anchors, aliases, collection styles, and source marks. This is useful for tools
that need to inspect YAML syntax before aliases, tags, or duplicate mapping keys
are resolved during construction.

An `IO` input is read when the iterator is created, so seekable and forward-only
streams are both supported. Invalid encoded input raises [`EncodingError`](@ref)
while the iterator is created. Characters whose invalidity can be established
during input validation raise [`ScannerError`](@ref) during the same step. Other
malformed decoded YAML raises only [`ScannerError`](@ref) or [`ParserError`](@ref)
as the iterator advances. Internal failures that cannot be attributed to source
text are rethrown rather than converted to input errors.

# Example

```jldoctest
julia> events = collect(YAMLEvents.parse_events("key: [value]"));

julia> [event.value for event in events if event isa YAMLEvents.ScalarEvent]
2-element Vector{String}:
 "key"
 "value"

julia> first(event for event in events if event isa YAMLEvents.SequenceStartEvent).flow_style
true
```
"""
function _parse_events(input::_PreparedInput)
    pkgversion(YAML) == v"0.4.16" || error("YAMLEvents requires YAML.jl 0.4.16")
    _validate_source_characters(input)
    tokenstream = YAML.TokenStream(IOBuffer(input.source))
    tokenstream.index == 1 || error("unsupported YAML backend index convention")
    needs_mapping = any(char -> char in ('\ufeff', '\'', '"', '\\', '%'), input.source)
    mapping_source = needs_mapping ? input.source : nothing
    mapping_tokenstream = needs_mapping ? YAML.TokenStream(IOBuffer(input.source)) : nothing
    line_start_positions = needs_mapping ? _line_start_positions(input.source) : nothing
    converter = _MarkConverter(mapping_source, input.newline_corrections,
                               input.character_count, line_start_positions,
                               mapping_tokenstream, 0, UInt64[], UInt64[],
                               firstindex(input.source), 0,
                               Dict{NTuple{3, UInt64}, Tuple{UInt64, UInt64}}(),
                               Dict{NTuple{3, UInt64}, Tuple{String, Mark}}(), false, false)
    state = _EventIteratorState(tokenstream, YAML.EventStream(tokenstream), converter,
                                input.encoding, nothing, false)
    return YAMLEventIterator(state)
end

parse_events(input::IO) = _parse_events(_prepare_input(input))
parse_events(input::AbstractString) = _parse_events(_prepare_input(input))
