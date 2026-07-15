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

function Base.showerror(io::IO, error::Union{ScannerError, ParserError})
    if error.context !== nothing
        print(io, error.context, " at ", error.context_mark, ": ")
    end
    print(io, error.problem, " at ", error.problem_mark)
    error isa ParserError && error.note !== nothing && print(io, ": ", error.note)
end
