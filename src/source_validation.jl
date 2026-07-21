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
    return _MarkConverter(input.source, input.newline_corrections,
                          input.character_count, nothing, nothing, 0, UInt64[], UInt64[],
                          firstindex(input.source), 0,
                          Dict{NTuple{3, UInt64}, Tuple{UInt64, UInt64}}(),
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
            _resolve_quoted_characters!(resolved, characters, positions,
                                        start_position, end_position)
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
