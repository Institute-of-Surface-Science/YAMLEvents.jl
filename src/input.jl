struct _PreparedInput
    source::String
    index_map::Vector{UInt64}
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
    input = collect(source)
    output = Char[]
    index_map = UInt64[0]
    original_index = UInt64(0)
    index = 1

    while index <= length(input)
        char = input[index]
        if char == '\r'
            push!(output, '\n')
            if index < length(input) && input[index + 1] == '\n'
                index += 1
                original_index += 1
            end
        else
            push!(output, char)
        end
        original_index += 1
        push!(index_map, original_index)
        index += 1
    end

    return String(output), index_map
end

function _prepare_input(source::AbstractString, encoding::String = "UTF-8")
    normalized, index_map = _normalize_newlines(source)
    return _PreparedInput(normalized, index_map, encoding)
end

function _prepare_input(input::IO)
    bytes = read(input)
    encoding = _detect_encoding(bytes)
    source = StringEncodings.decode(bytes, encoding)
    return _prepare_input(source, encoding)
end
