"""An error raised when byte input is not valid in its detected Unicode encoding."""
struct EncodingError <: Exception
    encoding::String
    byte_sequence::String
end

"""An error raised when YAML input cannot be tokenized."""
struct ScannerError <: Exception
    context::Union{String, Nothing}
    context_mark::Union{Mark, Nothing}
    problem::String
    problem_mark::Mark
end

"""An error raised when YAML tokens cannot form a document."""
struct ParserError <: Exception
    context::Union{String, Nothing}
    context_mark::Union{Mark, Nothing}
    problem::Union{String, Nothing}
    problem_mark::Union{Mark, Nothing}
    note::Union{String, Nothing}
end

function Base.showerror(io::IO, error::EncodingError)
    print(io, "invalid ", error.encoding, " byte sequence")
    isempty(error.byte_sequence) || print(io, " 0x", error.byte_sequence)
end

function Base.showerror(io::IO, error::Union{ScannerError, ParserError})
    if error.context !== nothing
        print(io, error.context, " at ", error.context_mark, ": ")
    end
    print(io, error.problem, " at ", error.problem_mark)
    error isa ParserError && error.note !== nothing && print(io, ": ", error.note)
end
