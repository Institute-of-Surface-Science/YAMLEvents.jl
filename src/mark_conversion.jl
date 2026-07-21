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
    unknown_directives::Vector{UnknownDirectiveEvent}
    reset_pending::Bool
    done::Bool
end

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
            source_index, source_position = _advance_skipped!(converter, source_index,
                                                              source_position,
                                                              backend_index)
        end
        if source_index <= ncodeunits(source) && _is_line_break(source[source_index])
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
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
    source_index, source_position, backend_index, line = _advance_normal(source,
                                                                         source_index,
                                                                         source_position,
                                                                         backend_index,
                                                                         line)

    while source_index <= ncodeunits(source)
        char = source[source_index]
        next_index = nextind(source, source_index)
        next_char = next_index <= ncodeunits(source) ? source[next_index] : '\0'

        if char == style && !(style == '\'' && next_char == '\'')
            break
        elseif _is_inline_space(char)
            while source_index <= ncodeunits(source) &&
                  _is_inline_space(source[source_index])
                source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                     source_index,
                                                                                     source_position,
                                                                                     backend_index,
                                                                                     line)
            end
            if source_index <= ncodeunits(source) && _is_line_break(source[source_index])
                source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                     source_index,
                                                                                     source_position,
                                                                                     backend_index,
                                                                                     line)
                source_index, source_position, backend_index,
                line = _record_flow_breaks!(converter, source_index, source_position,
                                            backend_index, line)
            end
        elseif _is_line_break(char)
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
                                                                                 line)
            source_index, source_position, backend_index,
            line = _record_flow_breaks!(converter, source_index, source_position,
                                        backend_index, line)
        elseif style == '\'' && char == '\'' && next_char == '\''
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
                                                                                 line)
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
                                                                                 line)
        elseif (style == '"' && char == '\'') ||
               (style == '\'' && (char == '"' || char == '\\'))
            source_index, source_position = _advance_skipped!(converter, source_index,
                                                              source_position,
                                                              backend_index)
        elseif style == '"' && char == '\\'
            source_index, source_position = _advance_skipped!(converter, source_index,
                                                              source_position,
                                                              backend_index)
            escaped = source[source_index]
            if haskey(YAML.ESCAPE_REPLACEMENTS, escaped)
                source_index, source_position = _advance_skipped!(converter, source_index,
                                                                  source_position,
                                                                  backend_index)
            elseif haskey(YAML.ESCAPE_CODES, escaped)
                digits = YAML.ESCAPE_CODES[escaped]
                source_index, source_position = _advance_skipped!(converter, source_index,
                                                                  source_position,
                                                                  backend_index)
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
                source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                     source_index,
                                                                                     source_position,
                                                                                     backend_index,
                                                                                     line)
                source_index, source_position, backend_index,
                line = _record_flow_breaks!(converter, source_index, source_position,
                                            backend_index, line)
            else
                error("could not align YAML double-quoted escape")
            end
        else
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
                                                                                 line)
        end
    end

    source_index <= ncodeunits(source) || error("unterminated YAML quoted scalar")
    source_index, source_position, backend_index, line = _advance_normal(source,
                                                                         source_index,
                                                                         source_position,
                                                                         backend_index,
                                                                         line)
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
            source_index, source_position = _advance_skipped!(converter, source_index,
                                                              source_position,
                                                              backend_index)
        else
            source_index, source_position, backend_index, line = _advance_normal(source,
                                                                                 source_index,
                                                                                 source_position,
                                                                                 backend_index,
                                                                                 line)
        end
        first_character = false
    end

    backend_index == end_mark.index || error("could not align YAML tag mark")
    converter.source_cursor = source_index
    converter.source_position = source_position
    return nothing
end

function _record_unknown_directive!(converter::_MarkConverter,
                                    token::YAML.DirectiveToken)
    converter.tokenstream === nothing && return nothing
    source = converter.source
    start_position = _normalized_index(converter, YAML.firstmark(token).index)
    content_position = _normalized_index(converter, YAML.lastmark(token).index)
    content_index = _source_index_at_position(source, content_position)
    content_index === nothing && error("could not align YAML directive source")

    end_index = content_index
    while end_index <= ncodeunits(source) && !_is_line_break(source[end_index])
        end_index = nextind(source, end_index)
    end
    end_position = _source_position_at_index(source, end_index)
    content = if content_index == end_index
        ""
    else
        String(SubString(source, content_index, prevind(source, end_index)))
    end

    push!(converter.unknown_directives,
          UnknownDirectiveEvent(_mark_at_source_position(converter, start_position),
                                _mark_at_source_position(converter, end_position),
                                token.name, content))
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
    elseif token isa YAML.DirectiveToken && token.name != "YAML"
        _record_unknown_directive!(converter, token)
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

function _source_index_at_position(source::String, source_position::UInt64)
    source_position <= length(source) || return nothing
    return nextind(source, 0, Int(source_position) + 1)
end

function _source_position_at_index(source::String, source_index::Int)
    source_index == firstindex(source) && return UInt64(0)
    preceding = SubString(source, firstindex(source), prevind(source, source_index))
    return UInt64(length(preceding))
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

function _yaml_scanner_frame(backtrace, function_name::Symbol)
    scanner_path = normpath(joinpath(dirname(pathof(YAML)), "scanner.jl"))
    return any(stacktrace(backtrace)) do frame
        frame.func === function_name || return false
        return normpath(String(frame.file)) == scanner_path
    end
end

function _scanner_conversion_kind(exception, backtrace)
    if exception isa Base.CodePointError
        _yaml_scanner_frame(backtrace, :scan_flow_scalar_non_spaces) && return :unicode
    elseif exception isa OverflowError
        _yaml_scanner_frame(backtrace, :scan_yaml_directive_number) && return :directive
        _yaml_scanner_frame(backtrace, :scan_flow_scalar_non_spaces) && return :unicode
    end
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
                _scanner_conversion_kind(exception, catch_backtrace()) === nothing &&
                    rethrow()
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

function _record_mapping_token!(converter::_MarkConverter, token)
    _record_token_corrections!(converter, token)
    end_mark = YAML.lastmark(token)
    converter.scanned_index = max(converter.scanned_index, end_mark.index)
    return nothing
end

function _scan_mark_mapping!(converter::_MarkConverter, backend_index::UInt64)
    while !converter.done && converter.scanned_index < backend_index
        token = _next_mapping_token!(converter)
        token === nothing && break
        _record_mapping_token!(converter, token)
    end
    return nothing
end
