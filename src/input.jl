struct _PreparedInput
    source::String
    newline_corrections::Vector{UInt64}
    character_count::UInt64
    encoding::String
    character_restorations::Dict{Char, Char}
end

const _YAML_1_1_LINE_BREAKS = ('\u0085', '\u2028', '\u2029')

function _codepoint_name(char::Char)
    codepoint = UInt32(char)
    width = codepoint <= 0xffff ? 4 : 8
    return "U+" * uppercase(string(codepoint; base = 16, pad = width))
end

function _byte_sequence(bytes)
    return join(string(byte; base = 16, pad = 2) for byte in bytes)
end

function _invalid_utf8_sequence(bytes)
    index = firstindex(bytes)
    last_index = lastindex(bytes)

    while index <= last_index
        first_byte = bytes[index]
        if first_byte <= 0x7f
            index += 1
            continue
        end

        width, second_min,
        second_max = if 0xc2 <= first_byte <= 0xdf
            2, 0x80, 0xbf
        elseif first_byte == 0xe0
            3, 0xa0, 0xbf
        elseif 0xe1 <= first_byte <= 0xec || 0xee <= first_byte <= 0xef
            3, 0x80, 0xbf
        elseif first_byte == 0xed
            3, 0x80, 0x9f
        elseif first_byte == 0xf0
            4, 0x90, 0xbf
        elseif 0xf1 <= first_byte <= 0xf3
            4, 0x80, 0xbf
        elseif first_byte == 0xf4
            4, 0x80, 0x8f
        else
            return bytes[index:index]
        end

        sequence_end = min(last_index, index + width - 1)
        sequence = bytes[index:sequence_end]
        length(sequence) == width || return sequence
        second_min <= sequence[2] <= second_max || return sequence
        all(byte -> 0x80 <= byte <= 0xbf, @view(sequence[3:end])) || return sequence
        index += width
    end

    return nothing
end

function _read_code_unit(bytes::Vector{UInt8}, index::Int, width::Int, little_endian::Bool)
    value = UInt32(0)
    for offset in 0:(width - 1)
        shift = little_endian ? 8 * offset : 8 * (width - offset - 1)
        value |= UInt32(bytes[index + offset]) << shift
    end
    return value
end

function _invalid_utf16_sequence(bytes::Vector{UInt8}, little_endian::Bool)
    index = firstindex(bytes)
    last_index = lastindex(bytes)
    while index <= last_index
        index + 1 <= last_index || return bytes[index:last_index]
        code_unit = _read_code_unit(bytes, index, 2, little_endian)
        if 0xd800 <= code_unit <= 0xdbff
            index + 3 <= last_index || return bytes[index:last_index]
            trailing = _read_code_unit(bytes, index + 2, 2, little_endian)
            0xdc00 <= trailing <= 0xdfff || return bytes[index:(index + 3)]
            index += 4
        elseif 0xdc00 <= code_unit <= 0xdfff
            return bytes[index:(index + 1)]
        else
            index += 2
        end
    end
    return nothing
end

function _invalid_utf32_sequence(bytes::Vector{UInt8}, little_endian::Bool)
    index = firstindex(bytes)
    last_index = lastindex(bytes)
    while index <= last_index
        index + 3 <= last_index || return bytes[index:last_index]
        codepoint = _read_code_unit(bytes, index, 4, little_endian)
        if codepoint > 0x10ffff || 0xd800 <= codepoint <= 0xdfff
            return bytes[index:(index + 3)]
        end
        index += 4
    end
    return nothing
end

function _validate_encoded_bytes(bytes::Vector{UInt8}, encoding::String)
    # StringEncodings/libiconv may silently discard an incomplete code unit at
    # EOF, so establish strict Unicode validity before decoding.
    invalid_sequence = if encoding == "UTF-8"
        _invalid_utf8_sequence(bytes)
    elseif encoding == "UTF-16BE"
        _invalid_utf16_sequence(bytes, false)
    elseif encoding == "UTF-16LE"
        _invalid_utf16_sequence(bytes, true)
    elseif encoding == "UTF-32BE"
        _invalid_utf32_sequence(bytes, false)
    elseif encoding == "UTF-32LE"
        _invalid_utf32_sequence(bytes, true)
    else
        error("unsupported input encoding $encoding")
    end

    invalid_sequence === nothing ||
        throw(EncodingError(encoding, _byte_sequence(invalid_sequence)))
    return nothing
end

function _validate_string_encoding(source::AbstractString, encoding::String)
    isvalid(source) && return nothing
    bytes = collect(codeunits(source))
    invalid_sequence = something(_invalid_utf8_sequence(bytes), bytes)
    throw(EncodingError(encoding, _byte_sequence(invalid_sequence)))
end

function _is_yaml_printable(char::Char)
    codepoint = UInt32(char)
    return codepoint in (0x09, 0x0a, 0x0d, 0x85) ||
           0x20 <= codepoint <= 0x7e ||
           0xa0 <= codepoint <= 0xd7ff ||
           0xe000 <= codepoint <= 0xfffd ||
           0x10000 <= codepoint <= 0x10ffff
end

function _has_prefix(bytes::Vector{UInt8}, prefix::Tuple{Vararg{UInt8}})
    length(bytes) >= length(prefix) || return false
    return all(index -> bytes[index] == prefix[index], eachindex(prefix))
end

function _detect_encoding(bytes::Vector{UInt8})
    if _has_prefix(bytes, (0x00, 0x00, 0xfe, 0xff))
        return "UTF-32BE"
    elseif _has_prefix(bytes, (0xff, 0xfe, 0x00, 0x00))
        return "UTF-32LE"
    elseif _has_prefix(bytes, (0xef, 0xbb, 0xbf))
        return "UTF-8"
    elseif _has_prefix(bytes, (0xfe, 0xff))
        return "UTF-16BE"
    elseif _has_prefix(bytes, (0xff, 0xfe))
        return "UTF-16LE"
    elseif length(bytes) >= 4 && bytes[1:3] == [0x00, 0x00, 0x00]
        return "UTF-32BE"
    elseif length(bytes) >= 4 && bytes[2:4] == [0x00, 0x00, 0x00]
        return "UTF-32LE"
    elseif length(bytes) >= 2 && bytes[1] == 0x00
        return "UTF-16BE"
    elseif length(bytes) >= 2 && bytes[2] == 0x00
        return "UTF-16LE"
    end
    return "UTF-8"
end

function _normalize_newlines(source::AbstractString)
    if !occursin('\r', source)
        normalized = String(source)
        return normalized, UInt64[], UInt64(length(normalized))
    end

    output = IOBuffer()
    newline_corrections = UInt64[]
    character_count = UInt64(0)
    index = firstindex(source)

    while index <= ncodeunits(source)
        char = source[index]
        next_index = nextind(source, index)
        if char == '\r'
            write(output, '\n')
            character_count += 1
            if next_index <= ncodeunits(source) && source[next_index] == '\n'
                push!(newline_corrections, character_count)
                index = nextind(source, next_index)
            else
                index = next_index
            end
        else
            write(output, char)
            character_count += 1
            index = next_index
        end
    end

    return String(take!(output)), newline_corrections, character_count
end

function _shield_yaml_1_2_characters(source::String)
    any(char -> char in _YAML_1_1_LINE_BREAKS, source) ||
        return source, Dict{Char, Char}()

    present = Set(source)
    shields = Dict{Char, Char}()
    restorations = Dict{Char, Char}()
    candidate = UInt32(0xa0)
    for character in _YAML_1_1_LINE_BREAKS
        while candidate <= 0x10ffff
            if !(0xd800 <= candidate <= 0xdfff)
                shield = Char(candidate)
                if _is_yaml_printable(shield) &&
                   shield != '\ufeff' &&
                   !(shield in _YAML_1_1_LINE_BREAKS) &&
                   !(shield in present)
                    shields[character] = shield
                    restorations[shield] = character
                    candidate += 1
                    break
                end
            end
            candidate += 1
        end
    end
    length(shields) == length(_YAML_1_1_LINE_BREAKS) ||
        error("could not reserve YAML 1.2 compatibility characters")

    output = IOBuffer()
    for character in source
        write(output, get(shields, character, character))
    end
    return String(take!(output)), restorations
end

function _throw_misplaced_bom(mark::Mark)
    throw(ScannerError(nothing, nothing,
                       "byte order mark must appear at the beginning of a document", mark))
end

function _prepare_input(source::AbstractString, encoding::String = "UTF-8")
    _validate_string_encoding(source, encoding)
    string_source = String(source)
    normalized, newline_corrections, character_count = _normalize_newlines(string_source)
    shielded, character_restorations = _shield_yaml_1_2_characters(normalized)
    return _PreparedInput(shielded, newline_corrections, character_count, encoding,
                          character_restorations)
end

function _prepare_input(input::IO)
    bytes = read(input)
    encoding = _detect_encoding(bytes)
    _validate_encoded_bytes(bytes, encoding)
    source = try
        StringEncodings.decode(bytes, encoding)
    catch exception
        if exception isa StringEncodings.InvalidSequenceError
            byte_sequence = isempty(exception.args) ? "" : string(first(exception.args))
            throw(EncodingError(encoding, byte_sequence))
        end
        rethrow()
    end
    return _prepare_input(source, encoding)
end
