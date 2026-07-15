struct _PreparedInput
    source::String
    newline_corrections::Vector{UInt64}
    character_count::UInt64
    encoding::String
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

function _prepare_input(source::AbstractString, encoding::String = "UTF-8")
    normalized, newline_corrections, character_count = _normalize_newlines(source)
    return _PreparedInput(normalized, newline_corrections, character_count, encoding)
end

function _prepare_input(input::IO)
    bytes = read(input)
    encoding = _detect_encoding(bytes)
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
